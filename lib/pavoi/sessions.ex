defmodule Pavoi.Sessions do
  @moduledoc """
  The Sessions context handles live streaming sessions, session products, and real-time state management.
  """

  import Ecto.Query, warn: false
  alias Pavoi.Repo

  alias Pavoi.Catalog.{ProductImage, ProductVariant}
  alias Pavoi.Sessions.{MessagePreset, Session, SessionProduct, SessionState}

  # Default color for host messages
  @default_message_color "amber"

  @doc """
  Returns the default color for host messages.
  """
  def default_message_color, do: @default_message_color

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
    ordered_variants = from(pv in ProductVariant, order_by: [asc: pv.position])

    Session
    |> order_by([s], desc: s.updated_at)
    |> preload([
      :brand,
      session_products: [
        product: [
          product_images: ^ordered_images,
          product_variants: ^ordered_variants
        ]
      ]
    ])
    |> Repo.all()
  end

  @doc """
  Returns a paginated list of sessions with brands and products preloaded, ordered by most recently modified.

  ## Options
    * `:page` - The page number to fetch (default: 1)
    * `:per_page` - Number of sessions per page (default: 20)
    * `:search_query` - Optional search query to filter by name or notes (default: "")

  ## Returns
  A map with the following keys:
    * `:sessions` - List of session structs with preloaded associations
    * `:page` - Current page number
    * `:per_page` - Number of sessions per page
    * `:total` - Total count of sessions
    * `:has_more` - Boolean indicating if there are more sessions to load
  """
  def list_sessions_with_details_paginated(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 20)
    search_query = Keyword.get(opts, :search_query, "")

    ordered_images = from(pi in ProductImage, order_by: [asc: pi.position])
    ordered_variants = from(pv in ProductVariant, order_by: [asc: pv.position])

    base_query =
      Session
      |> order_by([s], desc: s.updated_at)

    # Apply search filter if provided
    base_query =
      if search_query != "" do
        search_pattern = "%#{search_query}%"

        where(
          base_query,
          [s],
          ilike(s.name, ^search_pattern) or ilike(s.notes, ^search_pattern)
        )
      else
        base_query
      end

    total = Repo.aggregate(base_query, :count)

    sessions =
      base_query
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> preload([
        :brand,
        session_products: [
          product: [
            product_images: ^ordered_images,
            product_variants: ^ordered_variants
          ]
        ]
      ])
      |> Repo.all()

    %{
      sessions: sessions,
      page: page,
      per_page: per_page,
      total: total,
      has_more: total > page * per_page
    }
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
    |> broadcast_session_list_change()
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
  Duplicates an existing session with all its products.

  Creates a new session with the same brand, notes, and product lineup as the original.
  The new session will have "Copy of " prepended to its name and a unique slug.
  All session products are duplicated with their positions, sections, featured overrides, and notes.

  Returns {:ok, session} or {:error, changeset}.
  """
  def duplicate_session(session_id) do
    Repo.transaction(fn ->
      # Load the original session with products
      original_session = get_session!(session_id)

      # Generate new name and slug
      new_name = "Copy of #{original_session.name}"
      new_slug = generate_unique_slug(new_name)

      # Create new session with same attributes
      session_attrs = %{
        brand_id: original_session.brand_id,
        name: new_name,
        slug: new_slug,
        notes: original_session.notes
      }

      # Create the new session
      with {:ok, new_session} <- create_session(session_attrs),
           :ok <- duplicate_session_products(original_session.session_products, new_session.id) do
        new_session
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Duplicates all session products from the source session to a new session.
  # Copies all product associations including positions, overrides, and notes.
  # Returns :ok if all products are duplicated successfully, or {:error, changeset}
  # on the first failure. Uses reduce_while for early exit on error.
  defp duplicate_session_products(session_products, new_session_id) do
    session_products
    |> Enum.reduce_while(:ok, fn sp, _acc ->
      attrs = %{
        session_id: new_session_id,
        product_id: sp.product_id,
        position: sp.position,
        section: sp.section,
        featured_name: sp.featured_name,
        featured_talking_points_md: sp.featured_talking_points_md,
        featured_original_price_cents: sp.featured_original_price_cents,
        featured_sale_price_cents: sp.featured_sale_price_cents,
        notes: sp.notes
      }

      case Repo.insert(SessionProduct.changeset(%SessionProduct{}, attrs)) do
        {:ok, _} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp generate_unique_slug(name) do
    base_slug = slugify(name)
    ensure_unique_slug(base_slug, 0)
  end

  # Recursively ensures a slug is unique by appending a numeric suffix if needed.
  # On the first attempt (0), tries the base slug. If taken, appends -1, -2, etc.
  # Returns the first available slug. Example: "my-session" -> "my-session-2"
  defp ensure_unique_slug(base_slug, attempt) do
    slug = if attempt == 0, do: base_slug, else: "#{base_slug}-#{attempt}"

    case Repo.get_by(Session, slug: slug) do
      nil -> slug
      _ -> ensure_unique_slug(base_slug, attempt + 1)
    end
  end

  @doc """
  Converts a name string into a URL-friendly slug.

  Returns a lowercase string with spaces replaced by hyphens and special
  characters removed. Falls back to a timestamp-based slug if the result is empty.

  ## Examples

      iex> Sessions.slugify("My Session Name")
      "my-session-name"

      iex> Sessions.slugify("@#$%")
      "session-1234567890"
  """
  def slugify(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^\w\s-]/, "")
      |> String.replace(~r/\s+/, "-")
      |> String.trim("-")

    # Fallback for empty slugs
    if slug == "", do: "session-#{:os.system_time(:second)}", else: slug
  end

  @doc """
  Updates a session.
  """
  def update_session(%Session{} = session, attrs) do
    session
    |> Session.changeset(attrs)
    |> Repo.update()
    |> broadcast_session_list_change()
  end

  @doc """
  Deletes a session.
  """
  def delete_session(%Session{} = session) do
    Repo.delete(session)
    |> broadcast_session_list_change()
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
    ordered_variants = from(pv in ProductVariant, order_by: [asc: pv.position])

    SessionProduct
    |> preload(
      product: [:brand, product_images: ^ordered_images, product_variants: ^ordered_variants]
    )
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
    |> broadcast_session_list_change()
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
            |> broadcast_session_list_change()

          error ->
            error
        end
    end
  end

  @doc """
  Reorders session products based on a list of session_product IDs.

  Takes a session_id and a list of session_product IDs in the desired order.
  Updates the position field for each session_product efficiently using batch updates.

  Returns {:ok, count} where count is the number of updated records, or
  {:error, reason} if validation fails.
  """
  def reorder_products(session_id, ordered_session_product_ids) do
    # Validate input
    with {:ok, _session} <- validate_session_exists(session_id),
         :ok <- validate_no_duplicates(ordered_session_product_ids),
         {:ok, valid_ids} <-
           validate_session_product_ownership(session_id, ordered_session_product_ids) do
      # Proceed with reordering
      result =
        Repo.transaction(fn ->
          # Step 1: Move all products to temporary positions to avoid constraint violations
          # Use a high offset (10000) to ensure no conflicts with existing positions
          valid_ids
          |> Enum.with_index(1)
          |> Enum.each(fn {session_product_id, index} ->
            temp_position = 10_000 + index

            from(sp in SessionProduct,
              where: sp.id == ^session_product_id and sp.session_id == ^session_id
            )
            |> Repo.update_all(set: [position: temp_position])
          end)

          # Step 2: Update each product to its final position
          count =
            valid_ids
            # Start positions at 1
            |> Enum.with_index(1)
            |> Enum.map(fn {session_product_id, new_position} ->
              from(sp in SessionProduct,
                where: sp.id == ^session_product_id and sp.session_id == ^session_id
              )
              |> Repo.update_all(set: [position: new_position])
              # Returns {count, nil}, we want count
              |> elem(0)
            end)
            |> Enum.sum()

          # Touch the session to update its modified timestamp
          touch_session(session_id)

          count
        end)

      case result do
        {:ok, count} ->
          broadcast_session_list_change({:ok, count})
          {:ok, count}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp validate_session_exists(session_id) do
    case Repo.get(Session, session_id) do
      nil -> {:error, :session_not_found}
      session -> {:ok, session}
    end
  end

  defp validate_no_duplicates(ids) do
    if length(ids) == length(Enum.uniq(ids)) do
      :ok
    else
      {:error, :duplicate_ids}
    end
  end

  defp validate_session_product_ownership(session_id, session_product_ids) do
    # Query all session_products that match the provided IDs and belong to the session
    valid_ids =
      from(sp in SessionProduct,
        where: sp.session_id == ^session_id and sp.id in ^session_product_ids,
        select: sp.id
      )
      |> Repo.all()

    if length(valid_ids) == length(session_product_ids) do
      {:ok, session_product_ids}
    else
      {:error, :invalid_session_product_ids}
    end
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
  def send_host_message(session_id, message_text, color \\ @default_message_color) do
    message_id = generate_message_id()
    timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

    update_session_state(session_id, %{
      current_host_message_text: message_text,
      current_host_message_id: message_id,
      current_host_message_timestamp: timestamp,
      current_host_message_color: color
    })
  end

  @doc """
  Clears the current host message from the session state.
  """
  def clear_host_message(session_id) do
    update_session_state(session_id, %{
      current_host_message_text: nil,
      current_host_message_id: nil,
      current_host_message_timestamp: nil,
      current_host_message_color: nil
    })
  end

  ## Message Presets

  @doc """
  Returns the list of message presets, ordered by position.
  """
  def list_message_presets do
    MessagePreset
    |> order_by([mp], asc: mp.position)
    |> Repo.all()
  end

  @doc """
  Gets a single message preset.

  Raises `Ecto.NoResultsError` if the message preset does not exist.
  """
  def get_message_preset!(id), do: Repo.get!(MessagePreset, id)

  @doc """
  Creates a message preset.
  """
  def create_message_preset(attrs \\ %{}) do
    # If no position provided, set it to be last
    attrs =
      if Map.has_key?(attrs, :position) or Map.has_key?(attrs, "position") do
        attrs
      else
        max_position =
          MessagePreset
          |> select([mp], max(mp.position))
          |> Repo.one()

        Map.put(attrs, :position, (max_position || 0) + 1)
      end

    %MessagePreset{}
    |> MessagePreset.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Deletes a message preset.
  """
  def delete_message_preset(%MessagePreset{} = message_preset) do
    Repo.delete(message_preset)
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

    Repo.transaction(fn ->
      # Update positions sequentially, starting from 1
      updated_count =
        session_products
        |> Enum.with_index(1)
        |> Enum.count(fn {sp, new_position} ->
          update_session_product_position({sp, new_position}) != :ok
        end)

      # Touch session to update its timestamp
      touch_session(session_id)

      {:ok, updated_count}
    end)
    |> case do
      {:ok, {:ok, count}} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
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
      Pavoi.PubSub,
      "session:#{state.session_id}:state",
      {:state_changed, state}
    )

    {:ok, state}
  end

  defp broadcast_state_change(error), do: error

  defp broadcast_session_list_change(result) do
    case result do
      {:ok, _} ->
        Phoenix.PubSub.broadcast(
          Pavoi.PubSub,
          "sessions:list",
          {:session_list_changed}
        )

        result

      error ->
        error
    end
  end

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
