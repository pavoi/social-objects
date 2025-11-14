defmodule HudsonWeb.SessionsLive.Index do
  @moduledoc """
  Live view for managing sessions and their products.

  ## Stream + LiveComponent Pattern

  This module uses Phoenix LiveView streams for rendering product grids with live components
  for items that have dynamic state. The pattern is simple:

  ### Key Components:
  - `:new_session_products` stream - contains products for the "New Session" modal
  - `:add_product_products` stream - contains products for the "Add Products" modal
  - `:selected_product_ids` assign - MapSet tracking selected products for new session
  - `:add_product_selected_ids` assign - MapSet tracking selected products to add
  - `ProductComponents.SelectCardComponent` - live_component that renders selectable product cards

  ### The Pattern:

  1. **Maintain selection state in plain MapSet assigns**
     - No special handling needed here, just normal assign updates

  2. **Use live_components for items with dynamic state**
     - Product cards use SelectCardComponent (a live_component)
     - Live components automatically re-render when their props change
     - When `selected_ids` changes, all cards re-render automatically
     - No need for stream_update or special coordination

  3. **Keep event handlers simple**
     - Just update the selection MapSet
     - The live components handle the UI updates automatically

  ### Example (in toggle handlers):
  ```elixir
  def handle_event("toggle_product_selection", %{"product-id" => product_id}, socket) do
    product_id = normalize_id(product_id)
    selected_ids = socket.assigns.selected_product_ids

    new_selected_ids =
      if MapSet.member?(selected_ids, product_id) do
        MapSet.delete(selected_ids, product_id)
      else
        MapSet.put(selected_ids, product_id)
      end

    {:noreply, assign(socket, :selected_product_ids, new_selected_ids)}
    # That's it! The SelectCardComponent props update automatically,
    # triggering re-renders of affected cards.
  end
  ```

  ### Why this works:

  - Streams (`phx-update="stream"`) efficiently manage the list
  - Live components efficiently manage dynamic state/interactivity
  - Each piece handles what it's optimized for
  - No complex coordination needed

  See HudsonWeb.ProductComponents for template implementation details.
  """
  use HudsonWeb, :live_view

  alias Hudson.Catalog
  alias Hudson.Catalog.Product
  alias Hudson.Sessions
  alias Hudson.Sessions.{Session, SessionProduct}

  import HudsonWeb.ProductComponents

  @impl true
  def mount(_params, _session, socket) do
    sessions = Sessions.list_sessions_with_details()
    brands = Catalog.list_brands()

    socket =
      socket
      |> assign(:sessions, sessions)
      |> assign(:previous_sessions, sessions)
      |> assign(:brands, brands)
      |> assign(:expanded_session_ids, MapSet.new())
      |> assign(:selected_session_for_product, nil)
      |> assign(:available_products, [])
      |> assign(:show_modal_for_session, nil)
      |> assign(:show_new_session_modal, false)
      |> assign(:editing_product, nil)
      |> assign(
        :product_form,
        to_form(SessionProduct.changeset(%SessionProduct{}, %{}))
      )
      |> assign(
        :session_form,
        to_form(Session.changeset(%Session{}, %{}))
      )
      |> assign(
        :product_edit_form,
        to_form(Product.changeset(%Product{}, %{}))
      )
      |> assign(:editing_session, nil)
      |> assign(
        :session_edit_form,
        to_form(Session.changeset(%Session{}, %{}))
      )
      |> assign(:product_search_query, "")
      |> assign(:product_page, 1)
      |> assign(:product_total_count, 0)
      |> assign(:selected_product_ids, MapSet.new())
      |> assign(:new_session_has_more, false)
      |> assign(:loading_products, false)
      |> assign(:new_session_products_map, %{})
      |> stream(:new_session_products, [])
      |> assign(:add_product_search_query, "")
      |> assign(:add_product_page, 1)
      |> assign(:add_product_total_count, 0)
      |> assign(:add_product_selected_ids, MapSet.new())
      |> assign(:add_product_has_more, false)
      |> assign(:loading_add_products, false)
      |> assign(:add_product_products_map, %{})
      |> stream(:add_product_products, [])

    {:ok, socket}
  end

  @impl true
  def handle_event("keydown", %{"key" => "Escape"}, socket) do
    # Only close expanded sessions if no modal is currently open
    # If a modal is open, let the modal's own Escape handler close it first
    modal_open? =
      socket.assigns.show_new_session_modal or socket.assigns.selected_session_for_product != nil or
        socket.assigns.editing_product != nil or socket.assigns.editing_session != nil

    if modal_open? do
      {:noreply, socket}
    else
      # Close all expanded sessions on Escape
      {:noreply, assign(socket, :expanded_session_ids, MapSet.new())}
    end
  end

  @impl true
  def handle_event("toggle_expand", %{"session-id" => session_id}, socket) do
    session_id = normalize_id(session_id)
    expanded = socket.assigns.expanded_session_ids

    new_expanded =
      if MapSet.member?(expanded, session_id) do
        MapSet.delete(expanded, session_id)
      else
        MapSet.put(expanded, session_id)
      end

    {:noreply, assign(socket, :expanded_session_ids, new_expanded)}
  end

  @impl true
  def handle_event("stop_propagation", _params, socket) do
    # No-op handler to prevent event bubbling to parent elements
    {:noreply, socket}
  end

  @impl true
  def handle_event("load_products_for_session", %{"session-id" => session_id}, socket) do
    session_id = normalize_id(session_id)
    session = Enum.find(socket.assigns.sessions, &(&1.id == session_id))

    socket =
      socket
      |> assign(:selected_session_for_product, session)
      |> assign(:add_product_search_query, "")
      |> assign(:add_product_page, 1)
      |> assign(:add_product_selected_ids, MapSet.new())
      |> stream(:add_product_products, [], reset: true)
      |> assign(:add_product_has_more, false)
      |> assign(:loading_add_products, true)
      |> load_products_for_add_modal()

    {:noreply, socket}
  end

  @impl true
  def handle_event("validate_product", %{"session_product" => params}, socket) do
    changeset =
      %SessionProduct{}
      |> SessionProduct.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :product_form, to_form(changeset))}
  end

  @impl true
  def handle_event("validate_product", %{"product" => product_params}, socket) do
    changeset =
      socket.assigns.editing_product
      |> Product.changeset(product_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :product_edit_form, to_form(changeset))}
  end

  @impl true
  def handle_event("close_product_modal", _params, socket) do
    socket =
      socket
      |> assign(:selected_session_for_product, nil)
      |> assign(:show_modal_for_session, nil)
      |> assign(
        :product_form,
        to_form(SessionProduct.changeset(%SessionProduct{}, %{}))
      )
      |> assign(:add_product_search_query, "")
      |> assign(:add_product_page, 1)
      |> assign(:add_product_selected_ids, MapSet.new())
      |> stream(:add_product_products, [], reset: true)
      |> assign(:add_product_has_more, false)
      |> assign(:loading_add_products, false)

    {:noreply, socket}
  end

  @impl true
  def handle_event("show_new_session_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_new_session_modal, true)
      |> assign(:product_search_query, "")
      |> assign(:product_page, 1)
      |> assign(:selected_product_ids, MapSet.new())
      |> assign(:new_session_products, [])
      |> assign(:new_session_has_more, false)

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_new_session_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_new_session_modal, false)
      |> assign(
        :session_form,
        to_form(Session.changeset(%Session{}, %{}))
      )

    {:noreply, socket}
  end

  @impl true
  def handle_event("validate_session", %{"session" => params}, socket) do
    changeset =
      %Session{}
      |> Session.changeset(params)
      |> Map.put(:action, :validate)

    socket =
      socket
      |> assign(:session_form, to_form(changeset))

    # If brand changed, reload products
    socket =
      if params["brand_id"] && params["brand_id"] != "" do
        load_products_for_new_session(socket)
      else
        socket
        |> assign(:new_session_products, [])
        |> assign(:new_session_has_more, false)
        |> assign(:product_search_query, "")
        |> assign(:selected_product_ids, MapSet.new())
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("save_session", %{"session" => session_params}, socket) do
    # Generate slug from name
    slug = slugify(session_params["name"])
    session_params = Map.put(session_params, "slug", slug)

    # Extract selected product IDs (as list in order)
    selected_ids = MapSet.to_list(socket.assigns.selected_product_ids)

    case Sessions.create_session_with_products(session_params, selected_ids) do
      {:ok, _session} ->
        # Preserve expanded state across reload
        expanded_ids = socket.assigns.expanded_session_ids
        previous_sessions = socket.assigns.sessions
        new_sessions = Sessions.list_sessions_with_details()
        sorted_sessions = sort_sessions_preserving_expanded(new_sessions, expanded_ids, previous_sessions)

        socket =
          socket
          |> assign(:sessions, sorted_sessions)
          |> assign(:previous_sessions, sorted_sessions)
          |> assign(:expanded_session_ids, expanded_ids)
          |> assign(:show_new_session_modal, false)
          |> assign(
            :session_form,
            to_form(Session.changeset(%Session{}, %{}))
          )
          |> assign(:product_search_query, "")
          |> assign(:product_page, 1)
          |> assign(:selected_product_ids, MapSet.new())
          |> assign(:new_session_products, [])
          |> assign(:new_session_has_more, false)
          |> put_flash(:info, "Session created successfully")

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        socket =
          socket
          |> assign(:session_form, to_form(changeset))
          |> put_flash(:error, "Please fix the errors below")

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save_products_to_session", _params, socket) do
    session_id = socket.assigns.selected_session_for_product.id
    selected_ids = MapSet.to_list(socket.assigns.add_product_selected_ids)

    # Add each product to the end of the queue
    case add_products_to_session(session_id, selected_ids) do
      :ok ->
        # Preserve expanded state across reload
        expanded_ids = socket.assigns.expanded_session_ids
        previous_sessions = socket.assigns.sessions
        new_sessions = Sessions.list_sessions_with_details()
        sorted_sessions = sort_sessions_preserving_expanded(new_sessions, expanded_ids, previous_sessions)

        socket =
          socket
          |> assign(:sessions, sorted_sessions)
          |> assign(:previous_sessions, sorted_sessions)
          |> assign(:expanded_session_ids, expanded_ids)
          |> assign(:selected_session_for_product, nil)
          |> assign(:show_modal_for_session, nil)
          |> assign(:add_product_search_query, "")
          |> assign(:add_product_page, 1)
          |> assign(:add_product_selected_ids, MapSet.new())
          |> stream(:add_product_products, [], reset: true)
          |> assign(:add_product_has_more, false)
          |> put_flash(:info, "#{Enum.count(selected_ids)} product(s) added to session")

        {:noreply, socket}

      {:error, reason} ->
        socket =
          socket
          |> put_flash(:error, "Failed to add products: #{reason}")

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("search_add_products", %{"value" => query}, socket) do
    socket =
      socket
      |> assign(:add_product_search_query, query)
      |> assign(:add_product_page, 1)
      |> assign(:loading_add_products, true)
      |> load_products_for_add_modal()

    {:noreply, socket}
  end

  @impl true
  def handle_event("load_more_add_products", _params, socket) do
    socket =
      socket
      |> assign(:loading_add_products, true)
      |> load_products_for_add_modal(append: true)

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_add_product_selection", %{"product-id" => product_id}, socket) do
    product_id = normalize_id(product_id)
    selected_ids = socket.assigns.add_product_selected_ids

    new_selected_ids =
      if MapSet.member?(selected_ids, product_id) do
        MapSet.delete(selected_ids, product_id)
      else
        MapSet.put(selected_ids, product_id)
      end

    # Find the product in the map and update it with the new selected state
    product = find_product_in_stream(socket.assigns.add_product_products_map, product_id)

    socket =
      socket
      |> assign(:add_product_selected_ids, new_selected_ids)

    # Update the product in the stream with the new selected state
    socket =
      if product do
        updated_product = Map.put(product, :selected, MapSet.member?(new_selected_ids, product_id))
        stream_insert(socket, :add_product_products, updated_product)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("remove_product", %{"session-product-id" => sp_id}, socket) do
    sp_id = normalize_id(sp_id)

    case Sessions.remove_product_from_session(sp_id) do
      {:ok, _session_product} ->
        # Preserve expanded state across reload
        expanded_ids = socket.assigns.expanded_session_ids
        previous_sessions = socket.assigns.sessions
        new_sessions = Sessions.list_sessions_with_details()
        sorted_sessions = sort_sessions_preserving_expanded(new_sessions, expanded_ids, previous_sessions)

        socket =
          socket
          |> assign(:sessions, sorted_sessions)
          |> assign(:previous_sessions, sorted_sessions)
          |> assign(:expanded_session_ids, expanded_ids)
          |> put_flash(:info, "Product removed from session")

        {:noreply, socket}

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Product not found in session")
        |> then(&{:noreply, &1})

      {:error, reason} ->
        socket
        |> put_flash(:error, "Failed to remove product: #{inspect(reason)}")
        |> then(&{:noreply, &1})
    end
  end

  def handle_event("move_product_up", %{"session-product-id" => sp_id}, socket) do
    move_product(socket, sp_id, :up)
  end

  def handle_event("move_product_down", %{"session-product-id" => sp_id}, socket) do
    move_product(socket, sp_id, :down)
  end

  def handle_event("delete_session", %{"session-id" => session_id}, socket) do
    session_id = normalize_id(session_id)
    session = Sessions.get_session!(session_id)

    case Sessions.delete_session(session) do
      {:ok, _session} ->
        # Preserve expanded state across reload (and remove deleted session)
        expanded_ids = MapSet.delete(socket.assigns.expanded_session_ids, session_id)
        previous_sessions = socket.assigns.sessions
        new_sessions = Sessions.list_sessions_with_details()
        sorted_sessions = sort_sessions_preserving_expanded(new_sessions, expanded_ids, previous_sessions)

        socket =
          socket
          |> assign(:sessions, sorted_sessions)
          |> assign(:previous_sessions, sorted_sessions)
          |> assign(:expanded_session_ids, expanded_ids)
          |> put_flash(:info, "Session deleted successfully")

        {:noreply, socket}

      {:error, _changeset} ->
        socket =
          socket
          |> put_flash(:error, "Failed to delete session")

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("show_edit_product_modal", %{"product-id" => product_id}, socket) do
    product = Catalog.get_product_with_images!(product_id)

    # Convert prices from cents to dollars for display by passing as changes
    changes = %{
      "original_price_cents" => format_cents_to_dollars(product.original_price_cents),
      "sale_price_cents" => format_cents_to_dollars(product.sale_price_cents)
    }

    changeset = Product.changeset(product, changes)

    socket =
      socket
      |> assign(:editing_product, product)
      |> assign(:product_edit_form, to_form(changeset))

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_edit_product_modal", _params, socket) do
    socket =
      socket
      |> assign(:editing_product, nil)
      |> assign(:product_edit_form, to_form(Product.changeset(%Product{}, %{})))

    {:noreply, socket}
  end

  @impl true
  def handle_event("show_edit_session_modal", %{"session-id" => session_id}, socket) do
    session_id = normalize_id(session_id)
    session = Sessions.get_session!(session_id)
    changeset = Session.changeset(session, %{})

    socket =
      socket
      |> assign(:editing_session, session)
      |> assign(:session_edit_form, to_form(changeset))

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_edit_session_modal", _params, socket) do
    socket =
      socket
      |> assign(:editing_session, nil)
      |> assign(:session_edit_form, to_form(Session.changeset(%Session{}, %{})))

    {:noreply, socket}
  end

  @impl true
  def handle_event("validate_edit_session", %{"session" => params}, socket) do
    changeset =
      socket.assigns.editing_session
      |> Session.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :session_edit_form, to_form(changeset))}
  end

  @impl true
  def handle_event("update_session", %{"session" => session_params}, socket) do
    # Generate slug from name
    slug = slugify(session_params["name"])
    session_params = Map.put(session_params, "slug", slug)

    case Sessions.update_session(socket.assigns.editing_session, session_params) do
      {:ok, _session} ->
        # Preserve expanded state across reload
        expanded_ids = socket.assigns.expanded_session_ids
        previous_sessions = socket.assigns.sessions
        new_sessions = Sessions.list_sessions_with_details()
        sorted_sessions = sort_sessions_preserving_expanded(new_sessions, expanded_ids, previous_sessions)

        socket =
          socket
          |> assign(:sessions, sorted_sessions)
          |> assign(:previous_sessions, sorted_sessions)
          |> assign(:expanded_session_ids, expanded_ids)
          |> assign(:editing_session, nil)
          |> assign(:session_edit_form, to_form(Session.changeset(%Session{}, %{})))
          |> put_flash(:info, "Session updated successfully")

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        socket =
          socket
          |> assign(:session_edit_form, to_form(changeset))
          |> put_flash(:error, "Please fix the errors below")

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save_product", %{"product" => product_params}, socket) do
    # Convert price fields from dollars to cents
    product_params = convert_prices_to_cents(product_params)

    case Catalog.update_product(socket.assigns.editing_product, product_params) do
      {:ok, _product} ->
        # Refresh the sessions list
        expanded_ids = socket.assigns.expanded_session_ids
        previous_sessions = socket.assigns.sessions
        new_sessions = Sessions.list_sessions_with_details()
        sorted_sessions = sort_sessions_preserving_expanded(new_sessions, expanded_ids, previous_sessions)

        socket =
          socket
          |> assign(:sessions, sorted_sessions)
          |> assign(:previous_sessions, sorted_sessions)
          |> assign(:expanded_session_ids, expanded_ids)
          |> assign(:editing_product, nil)
          |> assign(:product_edit_form, to_form(Product.changeset(%Product{}, %{})))
          |> put_flash(:info, "Product updated successfully")

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        socket =
          socket
          |> assign(:product_edit_form, to_form(changeset))
          |> put_flash(:error, "Please fix the errors below")

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("search_products", %{"value" => query}, socket) do
    socket =
      socket
      |> assign(:product_search_query, query)
      |> assign(:product_page, 1)
      |> assign(:loading_products, true)
      |> load_products_for_new_session()

    {:noreply, socket}
  end

  @impl true
  def handle_event("load_more_products", _params, socket) do
    socket =
      socket
      |> assign(:loading_products, true)
      |> load_products_for_new_session(append: true)

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_product_selection", %{"product-id" => product_id}, socket) do
    product_id = normalize_id(product_id)
    selected_ids = socket.assigns.selected_product_ids

    new_selected_ids =
      if MapSet.member?(selected_ids, product_id) do
        MapSet.delete(selected_ids, product_id)
      else
        MapSet.put(selected_ids, product_id)
      end

    # Find the product in the map and update it with the new selected state
    product = find_product_in_stream(socket.assigns.new_session_products_map, product_id)

    socket =
      socket
      |> assign(:selected_product_ids, new_selected_ids)

    # Update the product in the stream with the new selected state
    socket =
      if product do
        updated_product = Map.put(product, :selected, MapSet.member?(new_selected_ids, product_id))
        stream_insert(socket, :new_session_products, updated_product)
      else
        socket
      end

    {:noreply, socket}
  end

  # Helper functions

  defp move_product(socket, sp_id, direction) do
    sp_id = normalize_id(sp_id)
    session = find_session_for_product(socket.assigns.sessions, sp_id)

    case session do
      nil ->
        socket
        |> put_flash(:error, "Session not found")
        |> then(&{:noreply, &1})

      session ->
        perform_product_swap(socket, sp_id, session, direction)
    end
  end

  defp perform_product_swap(socket, sp_id, session, direction) do
    case find_adjacent_product(session.session_products, sp_id, direction) do
      nil ->
        {:noreply, socket}

      adjacent_sp ->
        execute_product_swap(socket, sp_id, adjacent_sp.id)
    end
  end

  defp execute_product_swap(socket, sp_id, adjacent_sp_id) do
    case Sessions.swap_product_positions(sp_id, adjacent_sp_id) do
      {:ok, _} ->
        expanded_ids = socket.assigns.expanded_session_ids
        previous_sessions = socket.assigns.sessions
        new_sessions = Sessions.list_sessions_with_details()
        sorted_sessions = sort_sessions_preserving_expanded(new_sessions, expanded_ids, previous_sessions)

        socket =
          socket
          |> assign(:sessions, sorted_sessions)
          |> assign(:previous_sessions, sorted_sessions)
          |> assign(:expanded_session_ids, expanded_ids)

        {:noreply, socket}

      {:error, reason} ->
        socket
        |> put_flash(:error, "Failed to move product: #{inspect(reason)}")
        |> then(&{:noreply, &1})
    end
  end

  defp load_products_for_new_session(socket, opts \\ [append: false]) do
    append = Keyword.get(opts, :append, false)

    brand_id = get_in(socket.assigns.session_form.params, ["brand_id"])
    search_query = socket.assigns.product_search_query
    page = if append, do: socket.assigns.product_page + 1, else: 1

    case brand_id do
      nil ->
        socket
        |> assign(:loading_products, false)
        |> stream(:new_session_products, [], reset: true)
        |> assign(:new_session_has_more, false)
        |> assign(:product_total_count, 0)

      "" ->
        socket
        |> assign(:loading_products, false)
        |> stream(:new_session_products, [], reset: true)
        |> assign(:new_session_has_more, false)
        |> assign(:product_total_count, 0)

      brand_id_str ->
        try do
          brand_id = String.to_integer(brand_id_str)

          result =
            Catalog.search_products_paginated(
              brand_id: brand_id,
              search_query: search_query,
              page: page,
              per_page: 20
            )

          # Precompute primary images and include selected state
          products_with_state =
            Enum.map(result.products, fn product ->
              product_with_image = add_primary_image(product)
              Map.put(product_with_image, :selected, MapSet.member?(socket.assigns.selected_product_ids, product.id))
            end)

          # Build a map for quick lookup by product ID
          products_map =
            if append do
              socket.assigns.new_session_products_map
            else
              %{}
            end
            |> Map.merge(Map.new(products_with_state, &({&1.id, &1})))

          socket
          |> assign(:loading_products, false)
          |> assign(:new_session_products_map, products_map)
          |> stream(:new_session_products, products_with_state, reset: !append)
          |> assign(:product_total_count, result.total)
          |> assign(:product_page, result.page)
          |> assign(:new_session_has_more, result.has_more)
        rescue
          _e ->
            socket
            |> assign(:loading_products, false)
            |> put_flash(:error, "Failed to load products")
        end
    end
  end

  defp add_primary_image(product) do
    primary_image =
      product.product_images
      |> Enum.find(& &1.is_primary)
      |> case do
        nil -> List.first(product.product_images)
        image -> image
      end

    Map.put(product, :primary_image, primary_image)
  end

  defp format_cents_to_dollars(nil), do: nil
  defp format_cents_to_dollars(cents) when is_integer(cents) do
    cents / 100
  end

  defp convert_prices_to_cents(params) do
    params
    |> convert_price_field("original_price_cents")
    |> convert_price_field("sale_price_cents")
  end

  defp convert_price_field(params, field) do
    case Map.get(params, field) do
      nil ->
        params

      "" ->
        Map.put(params, field, nil)

      value when is_binary(value) ->
        parse_price_value(params, field, value)

      value when is_integer(value) ->
        params

      _ ->
        params
    end
  end

  defp parse_price_value(params, field, value) do
    case String.contains?(value, ".") do
      true -> convert_dollars_to_cents(params, field, value)
      false -> params
    end
  end

  defp convert_dollars_to_cents(params, field, value) do
    case Float.parse(value) do
      {dollars, _} -> Map.put(params, field, round(dollars * 100))
      :error -> params
    end
  end

  defp normalize_id(id) when is_integer(id), do: id
  defp normalize_id(id) when is_binary(id), do: String.to_integer(id)

  defp slugify(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^\w\s-]/, "")
      |> String.replace(~r/\s+/, "-")
      |> String.trim("-")

    # Fallback for empty slugs
    if slug == "", do: "session-#{:os.system_time(:second)}", else: slug
  end

  defp primary_image(product) do
    product.product_images
    |> Enum.find(& &1.is_primary)
    |> case do
      nil -> List.first(product.product_images)
      image -> image
    end
  end

  defp load_products_for_add_modal(socket, opts \\ [append: false]) do
    append = Keyword.get(opts, :append, false)

    session = socket.assigns.selected_session_for_product
    search_query = socket.assigns.add_product_search_query
    page = if append, do: socket.assigns.add_product_page + 1, else: 1

    case session do
      nil ->
        socket
        |> assign(:loading_add_products, false)
        |> stream(:add_product_products, [], reset: true)
        |> assign(:add_product_has_more, false)
        |> assign(:add_product_total_count, 0)

      _session ->
        try do
          # Get IDs of products already in the session
          existing_product_ids =
            session.session_products
            |> Enum.map(& &1.product_id)

          result =
            Catalog.search_products_paginated(
              brand_id: session.brand_id,
              search_query: search_query,
              exclude_ids: existing_product_ids,
              page: page,
              per_page: 20
            )

          # Precompute primary images and include selected state
          products_with_state =
            Enum.map(result.products, fn product ->
              product_with_image = add_primary_image(product)
              Map.put(product_with_image, :selected, MapSet.member?(socket.assigns.add_product_selected_ids, product.id))
            end)

          # Build a map for quick lookup by product ID
          products_map =
            if append do
              socket.assigns.add_product_products_map
            else
              %{}
            end
            |> Map.merge(Map.new(products_with_state, &({&1.id, &1})))

          socket
          |> assign(:loading_add_products, false)
          |> assign(:add_product_products_map, products_map)
          |> stream(:add_product_products, products_with_state, reset: !append)
          |> assign(:add_product_total_count, result.total)
          |> assign(:add_product_page, result.page)
          |> assign(:add_product_has_more, result.has_more)
        rescue
          _e ->
            socket
            |> assign(:loading_add_products, false)
            |> put_flash(:error, "Failed to load products")
        end
    end
  end

  defp add_products_to_session(session_id, product_ids) do
    # Get the next position for the first product
    next_position = Sessions.get_next_position_for_session(session_id)

    # Add each product with incrementing positions
    results =
      product_ids
      |> Enum.with_index()
      |> Enum.map(fn {product_id, index} ->
        Sessions.add_product_to_session(session_id, product_id, %{
          position: next_position + index
        })
      end)

    # Check if all additions were successful
    if Enum.all?(results, fn result -> match?({:ok, _}, result) end) do
      :ok
    else
      # Find the first error
      error =
        Enum.find(results, fn result -> match?({:error, _}, result) end)
        |> case do
          {:error, reason} -> reason
          _ -> "Unknown error"
        end

      {:error, error}
    end
  end

  defp find_session_for_product(sessions, session_product_id) do
    Enum.find(sessions, fn session ->
      Enum.any?(session.session_products, &(&1.id == session_product_id))
    end)
  end

  defp find_adjacent_product(session_products, sp_id, direction) do
    sp = Enum.find(session_products, &(&1.id == sp_id))

    case direction do
      :up ->
        Enum.find(session_products, &(&1.position == sp.position - 1))

      :down ->
        Enum.find(session_products, &(&1.position == sp.position + 1))
    end
  end

  defp find_product_in_stream(products_map, product_id) do
    Map.get(products_map, product_id)
  end

  def public_image_url(path) do
    Hudson.Media.public_image_url(path)
  end

  # Sorts sessions while preserving the display position of expanded sessions.
  #
  # This prevents the jarring experience of sessions jumping to the top when modified
  # while their accordion is expanded. Expanded sessions stay in place until collapsed.
  #
  # Algorithm:
  # 1. If no sessions are expanded, return the new list as-is (sorted by updated_at)
  # 2. If sessions are expanded:
  #    - Keep expanded sessions in their previous positions
  #    - Fill remaining positions with new/collapsed sessions sorted by updated_at
  #    - This maintains a stable view while editing
  defp sort_sessions_preserving_expanded(new_sessions, expanded_ids, previous_sessions) do
    if MapSet.size(expanded_ids) == 0 do
      # No expanded sessions - use database sort order
      new_sessions
    else
      # Build a map of session_id -> updated session data
      new_sessions_map = Map.new(new_sessions, &{&1.id, &1})

      # Build a map of position -> session_id for expanded sessions
      expanded_at_position =
        previous_sessions
        |> Enum.with_index()
        |> Enum.filter(fn {session, _idx} -> MapSet.member?(expanded_ids, session.id) end)
        |> Map.new(fn {session, idx} -> {idx, session.id} end)

      # Get non-expanded sessions sorted by updated_at (already sorted from DB)
      non_expanded_sessions =
        new_sessions
        |> Enum.reject(fn session -> MapSet.member?(expanded_ids, session.id) end)

      # Build result by going through each position and filling it appropriately
      {result, _remaining} =
        Enum.reduce(0..(length(previous_sessions) - 1), {[], non_expanded_sessions}, fn idx, {acc, remaining} ->
          case Map.get(expanded_at_position, idx) do
            nil ->
              # This position should have a non-expanded session
              case remaining do
                [next_session | rest] -> {acc ++ [next_session], rest}
                [] -> {acc, []}
              end

            session_id ->
              # This position should keep its expanded session (with fresh data)
              case Map.get(new_sessions_map, session_id) do
                nil -> {acc, remaining}
                session -> {acc ++ [session], remaining}
              end
          end
        end)

      result
    end
  end
end
