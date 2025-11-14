defmodule Hudson.Sessions do
  @moduledoc """
  The Sessions context handles live streaming sessions, session products, and real-time state management.
  """

  import Ecto.Query, warn: false
  alias Hudson.Repo

  alias Hudson.Catalog.ProductImage
  alias Hudson.Sessions.{Session, SessionProduct, SessionState}

  ## Sessions

  @doc """
  Returns the list of sessions.
  """
  def list_sessions do
    Repo.all(Session)
  end

  @doc """
  Returns the list of sessions with brands and products preloaded, ordered by most recently modified.
  """
  def list_sessions_with_details do
    ordered_images = from(pi in ProductImage, order_by: [asc: pi.position])

    Session
    |> order_by([s], desc: s.updated_at)
    |> preload([:brand, session_products: [product: [product_images: ^ordered_images]]])
    |> Repo.all()
  end

  @doc """
  Gets a single session.
  Raises `Ecto.NoResultsError` if the Session does not exist.
  """
  def get_session!(id) do
    ordered_images = from(pi in ProductImage, order_by: [asc: pi.position])

    Session
    |> preload(session_products: [product: [:brand, product_images: ^ordered_images]])
    |> Repo.get!(id)
  end

  @doc """
  Gets a session by slug.
  """
  def get_session_by_slug!(slug) do
    ordered_images = from(pi in ProductImage, order_by: [asc: pi.position])

    Session
    |> where([s], s.slug == ^slug)
    |> preload(session_products: [product: [:brand, product_images: ^ordered_images]])
    |> Repo.one!()
  end

  @doc """
  Creates a session.
  """
  def create_session(attrs \\ %{}) do
    %Session{}
    |> Session.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a session with products in a single transaction.

  Takes session attributes and a list of product IDs. Creates the session
  and then adds each product as a session_product with sequential positions.

  Returns {:ok, session} or {:error, changeset} on failure.
  """
  def create_session_with_products(session_attrs, product_ids \\ []) do
    Repo.transaction(fn ->
      with {:ok, session} <- create_session(session_attrs),
           :ok <- add_products_to_session(session.id, product_ids) do
        session
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp add_products_to_session(session_id, product_ids) do
    Enum.with_index(product_ids, 1)
    |> Enum.reduce_while(:ok, fn {product_id, position}, _acc ->
      case add_product_to_session(session_id, product_id, %{position: position}) do
        {:ok, _} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  @doc """
  Updates a session.
  """
  def update_session(%Session{} = session, attrs) do
    session
    |> Session.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a session.
  """
  def delete_session(%Session{} = session) do
    Repo.delete(session)
  end

  # Updates a session's updated_at timestamp to the current time.
  # This is useful to mark a session as recently modified when its products change.
  defp touch_session(session_id) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    from(s in Session, where: s.id == ^session_id)
    |> Repo.update_all(set: [updated_at: now])
  end

  ## Session Products

  @doc """
  Gets a single session product.
  """
  def get_session_product!(id) do
    ordered_images = from(pi in ProductImage, order_by: [asc: pi.position])

    SessionProduct
    |> preload(product: [:brand, product_images: ^ordered_images])
    |> Repo.get!(id)
  end

  @doc """
  Adds a product to a session with the given position and optional overrides.
  Also updates the session's updated_at timestamp to mark it as recently modified.
  """
  def add_product_to_session(session_id, product_id, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.put(:session_id, session_id)
      |> Map.put(:product_id, product_id)

    result =
      %SessionProduct{}
      |> SessionProduct.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, _} -> touch_session(session_id)
      error -> error
    end

    result
  end

  @doc """
  Removes a product from a session by deleting the session_product record.
  Automatically renumbers remaining products to fill any gaps and keep positions sequential.
  Also updates the session's updated_at timestamp to mark it as recently modified.
  """
  def remove_product_from_session(session_product_id) do
    case Repo.get(SessionProduct, session_product_id) do
      nil ->
        {:error, :not_found}

      session_product ->
        result = Repo.delete(session_product)

        case result do
          {:ok, _} ->
            # Auto-renumber positions to fill gaps
            renumber_session_products(session_product.session_id)
            result

          error ->
            error
        end
    end
  end

  @doc """
  Swaps the positions of two adjacent session products and renumbers the session.

  Uses a temporary position to avoid constraint violations, then renumbers all products
  to maintain sequential positions. This ensures positions always start at 1 and have no gaps.

  Returns {:ok, {product1, product2}} on success.
  """
  def swap_product_positions(session_product_id_1, session_product_id_2) do
    sp1 = Repo.get(SessionProduct, session_product_id_1)
    sp2 = Repo.get(SessionProduct, session_product_id_2)

    cond do
      is_nil(sp1) or is_nil(sp2) ->
        {:error, :not_found}

      sp1.session_id != sp2.session_id ->
        {:error, :different_sessions}

      true ->
        result =
          Repo.transaction(fn ->
            # Use temporary position to avoid constraint violations
            temp_pos = 999_999

            # Step 1: Move sp1 to temp position
            sp1
            |> Ecto.Changeset.change(position: temp_pos)
            |> Repo.update!()

            # Step 2: Move sp2 to sp1's original position
            sp2
            |> Ecto.Changeset.change(position: sp1.position)
            |> Repo.update!()

            # Step 3: Move sp1 from temp to sp2's original position
            sp1
            |> Ecto.Changeset.change(position: sp2.position)
            |> Repo.update!()

            # Renumber all products in the session to ensure sequential 1, 2, 3, etc.
            renumber_session_products_in_transaction(sp1.session_id)

            {sp1, sp2}
          end)

        # Touch the session's updated_at timestamp
        case result do
          {:ok, _} -> touch_session(sp1.session_id)
          error -> error
        end

        result
    end
  end

  # Helper to renumber products within an existing transaction
  defp renumber_session_products_in_transaction(session_id) do
    session_products =
      from(sp in SessionProduct,
        where: sp.session_id == ^session_id,
        order_by: [asc: sp.position]
      )
      |> Repo.all()

    session_products
    |> Enum.with_index(1)
    |> Enum.each(fn {sp, new_position} ->
      if sp.position != new_position do
        sp
        |> Ecto.Changeset.change(position: new_position)
        |> Repo.update!()
      end
    end)
  end

  @doc """
  Gets the next available position for a session.
  Uses database query to avoid race conditions.
  """
  def get_next_position_for_session(session_id) do
    max_position =
      from(sp in SessionProduct,
        where: sp.session_id == ^session_id,
        select: max(sp.position)
      )
      |> Repo.one()

    (max_position || 0) + 1
  end

  @doc """
  Gets adjacent session products (for preloading).
  Returns products at positions: current_position ± range.
  """
  def get_adjacent_session_products(session_id, current_position, range \\ 2) do
    ordered_images = from(pi in ProductImage, order_by: [asc: pi.position])

    from(sp in SessionProduct,
      where:
        sp.session_id == ^session_id and
          sp.position >= ^(current_position - range) and
          sp.position <= ^(current_position + range),
      order_by: [asc: sp.position],
      preload: [product: [:brand, product_images: ^ordered_images]]
    )
    |> Repo.all()
  end

  ## Session State Management

  @doc """
  Gets the current session state.
  """
  def get_session_state(session_id) do
    case Repo.get_by(SessionState, session_id: session_id) do
      nil ->
        {:error, :not_found}

      state ->
        # Preload with ordered images
        state =
          state
          |> Repo.preload(current_session_product: [product: :brand])
          |> Repo.preload(
            current_session_product: [
              product: [product_images: from(pi in ProductImage, order_by: [asc: pi.position])]
            ]
          )

        {:ok, state}
    end
  end

  @doc """
  Initializes session state to the first product.
  Uses upsert to handle cases where state row already exists.
  """
  def initialize_session_state(session_id) do
    # Get first session product
    first_sp =
      from(sp in SessionProduct,
        where: sp.session_id == ^session_id,
        order_by: [asc: sp.position],
        limit: 1
      )
      |> Repo.one()

    if first_sp do
      %SessionState{}
      |> SessionState.changeset(%{
        session_id: session_id,
        current_session_product_id: first_sp.id,
        current_image_index: 0
      })
      |> Repo.insert(
        on_conflict: {:replace, [:current_session_product_id, :current_image_index, :updated_at]},
        conflict_target: :session_id
      )
      |> broadcast_state_change()
    else
      {:error, :no_products}
    end
  end

  @doc """
  PRIMARY NAVIGATION: Jumps directly to a product by its position number.
  This is the main navigation method for the host view.
  """
  def jump_to_product(session_id, position) do
    case Repo.get_by(SessionProduct, session_id: session_id, position: position) do
      nil ->
        {:error, :invalid_position}

      sp ->
        update_session_state(session_id, %{
          current_session_product_id: sp.id,
          current_image_index: 0
        })
    end
  end

  @doc """
  CONVENIENCE: Advances to the next product in sequence.
  Used for arrow key navigation, not the primary method.
  """
  def advance_to_next_product(session_id) do
    with {:ok, current_state} <- get_session_state(session_id),
         {:ok, current_sp} <- get_current_session_product(current_state),
         {:ok, next_sp} <- get_next_session_product(session_id, current_sp.position) do
      update_session_state(session_id, %{
        current_session_product_id: next_sp.id,
        current_image_index: 0
      })
    else
      {:error, :no_next_product} -> {:error, :end_of_session}
      error -> error
    end
  end

  @doc """
  CONVENIENCE: Goes to the previous product in sequence.
  Used for arrow key navigation, not the primary method.
  """
  def go_to_previous_product(session_id) do
    with {:ok, current_state} <- get_session_state(session_id),
         {:ok, current_sp} <- get_current_session_product(current_state),
         {:ok, prev_sp} <- get_previous_session_product(session_id, current_sp.position) do
      update_session_state(session_id, %{
        current_session_product_id: prev_sp.id,
        current_image_index: 0
      })
    else
      {:error, :no_previous_product} -> {:error, :start_of_session}
      error -> error
    end
  end

  @doc """
  Cycles through product images (next or previous).
  """
  def cycle_product_image(session_id, direction) do
    with {:ok, state} <- get_session_state(session_id),
         {:ok, sp} <- get_current_session_product(state),
         product <- Repo.preload(sp.product, :product_images),
         image_count when image_count > 0 <- length(product.product_images) do
      new_index =
        case direction do
          :next -> rem(state.current_image_index + 1, image_count)
          :previous -> rem(state.current_image_index - 1 + image_count, image_count)
        end

      update_session_state(session_id, %{current_image_index: new_index})
    else
      0 -> {:error, :no_images}
      error -> error
    end
  end

  ## Host Messages

  @doc """
  Sends a message to the host by updating the session state.
  The message is persisted in the database and broadcast to all connected clients.
  """
  def send_host_message(session_id, message_text) do
    message_id = generate_message_id()
    timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

    update_session_state(session_id, %{
      current_host_message_text: message_text,
      current_host_message_id: message_id,
      current_host_message_timestamp: timestamp
    })
  end

  @doc """
  Clears the current host message from the session state.
  """
  def clear_host_message(session_id) do
    update_session_state(session_id, %{
      current_host_message_text: nil,
      current_host_message_id: nil,
      current_host_message_timestamp: nil
    })
  end

  @doc """
  Renumbers session product positions to be sequential starting from 1.
  Useful after deleting products that leave gaps in numbering.
  Also updates the session's updated_at timestamp to mark it as recently modified.
  """
  def renumber_session_products(session_id) do
    session_products =
      from(sp in SessionProduct,
        where: sp.session_id == ^session_id,
        order_by: [asc: sp.position]
      )
      |> Repo.all()

    result =
      Repo.transaction(fn ->
        session_products
        |> Enum.with_index(1)
        |> Enum.each(&update_session_product_position/1)
      end)

    case result do
      {:ok, _} -> touch_session(session_id)
      error -> error
    end

    result
  end

  defp update_session_product_position({sp, new_position}) when sp.position != new_position do
    sp
    |> Ecto.Changeset.change(position: new_position)
    |> Repo.update!()
  end

  defp update_session_product_position(_), do: :ok

  ## Private Helpers

  defp update_session_state(session_id, attrs) do
    Repo.transaction(fn ->
      # Lock the row to prevent concurrent updates
      state =
        from(ss in SessionState,
          where: ss.session_id == ^session_id,
          lock: "FOR UPDATE"
        )
        |> Repo.one!()
        |> SessionState.changeset(attrs)
        |> Repo.update!()

      broadcast_state_change({:ok, state})
      state
    end)
    |> case do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp broadcast_state_change({:ok, %SessionState{} = state}) do
    Phoenix.PubSub.broadcast(
      Hudson.PubSub,
      "session:#{state.session_id}:state",
      {:state_changed, state}
    )

    {:ok, state}
  end

  defp broadcast_state_change(error), do: error

  defp get_current_session_product(%SessionState{current_session_product_id: nil}),
    do: {:error, :no_current_product}

  defp get_current_session_product(state) do
    case Repo.get(SessionProduct, state.current_session_product_id) do
      nil ->
        {:error, :not_found}

      sp ->
        # Preload with ordered images
        sp =
          sp
          |> Repo.preload(product: :brand)
          |> Repo.preload(
            product: [product_images: from(pi in ProductImage, order_by: [asc: pi.position])]
          )

        {:ok, sp}
    end
  end

  defp get_next_session_product(session_id, current_position) do
    from(sp in SessionProduct,
      where: sp.session_id == ^session_id and sp.position > ^current_position,
      order_by: [asc: sp.position],
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :no_next_product}
      sp -> {:ok, sp}
    end
  end

  defp get_previous_session_product(session_id, current_position) do
    from(sp in SessionProduct,
      where: sp.session_id == ^session_id and sp.position < ^current_position,
      order_by: [desc: sp.position],
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :no_previous_product}
      sp -> {:ok, sp}
    end
  end

  defp generate_message_id do
    "msg_#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"
  end
end
