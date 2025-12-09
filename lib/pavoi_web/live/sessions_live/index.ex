defmodule PavoiWeb.SessionsLive.Index do
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

  See PavoiWeb.ProductComponents for template implementation details.
  """
  use PavoiWeb, :live_view

  on_mount {PavoiWeb.NavHooks, :set_current_page}

  alias Pavoi.AI
  alias Pavoi.Catalog
  alias Pavoi.Catalog.Product
  alias Pavoi.Sessions
  alias Pavoi.Sessions.{Session, SessionProduct}

  import PavoiWeb.AIComponents
  import PavoiWeb.ProductComponents
  import PavoiWeb.ViewHelpers

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to session list changes for real-time updates across tabs
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Pavoi.PubSub, "sessions:list")
      Phoenix.PubSub.subscribe(Pavoi.PubSub, "shopify:sync")
      Phoenix.PubSub.subscribe(Pavoi.PubSub, "ai:talking_points")
    end

    brands = Catalog.list_brands()

    socket =
      socket
      |> assign(:session_page, 1)
      |> assign(:sessions_has_more, false)
      |> assign(:loading_sessions, false)
      |> assign(:sessions, [])
      |> assign(:session_search_query, "")
      |> assign(:search_touched, false)
      |> assign(:brands, brands)
      |> load_sessions()
      |> assign(:expanded_session_id, nil)
      |> assign(:selected_session_for_product, nil)
      |> assign(:available_products, [])
      |> assign(:show_modal_for_session, nil)
      |> assign(:show_new_session_modal, false)
      |> assign(:editing_product, nil)
      |> assign(:current_image_index, 0)
      |> assign(:generating_in_modal, false)
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
      |> assign(:current_generation, nil)
      |> assign(:current_product_name, nil)
      |> assign(:show_generation_modal, false)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> apply_url_params(params)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:session_list_changed}, socket) do
    # Reload sessions from database while preserving UI state
    # Reset pagination to page 1 and reload
    socket =
      socket
      |> assign(:session_page, 1)
      |> load_sessions()

    {:noreply, socket}
  end

  @impl true
  def handle_info({:sync_started}, socket) do
    socket =
      socket
      |> put_flash(:info, "Syncing product catalog from Shopify...")

    {:noreply, socket}
  end

  @impl true
  def handle_info({:sync_completed, counts}, socket) do
    # Reload sessions to pick up any product changes
    # Reset pagination to page 1 and reload
    socket =
      socket
      |> assign(:session_page, 1)
      |> load_sessions()
      |> put_flash(
        :info,
        "Shopify sync complete: #{counts.products} products, #{counts.brands} brands, #{counts.images} images"
      )

    {:noreply, socket}
  end

  @impl true
  def handle_info({:sync_failed, reason}, socket) do
    message =
      case reason do
        :rate_limited -> "Shopify sync paused due to rate limiting, will retry soon"
        _ -> "Shopify sync failed: #{inspect(reason)}"
      end

    socket =
      socket
      |> put_flash(:error, message)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:generation_started, generation}, socket) do
    # Only show banner for batch (session-wide) generation
    socket =
      if generation.session_id do
        socket
        |> assign(:current_generation, generation)
        |> assign(:show_generation_modal, false)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:generation_progress, generation, _product_id, product_name}, socket) do
    # Only update banner for batch (session-wide) generation
    socket =
      if generation.session_id do
        socket
        |> assign(:current_generation, generation)
        |> assign(:current_product_name, product_name)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:generation_completed, generation}, socket) do
    # Update the generation status immediately so the banner shows completion (only for batch generation)
    socket =
      if generation.session_id do
        socket
        |> assign(:current_generation, generation)
        |> assign(:current_product_name, nil)
      else
        socket
      end
      |> assign(:generating_in_modal, false)

    # Only reload sessions if this was a session-wide generation
    # For single product generations, we don't need to reload the full list
    socket =
      if generation.session_id do
        # Reload just the affected session, not all sessions
        reload_single_session(socket, generation.session_id)
      else
        socket
      end

    # If a product modal is currently open, refresh it with updated talking points
    socket =
      if socket.assigns.editing_product do
        product = Catalog.get_product_with_images!(socket.assigns.editing_product.id)

        changes = %{
          "original_price_cents" => format_cents_to_dollars(product.original_price_cents),
          "sale_price_cents" => format_cents_to_dollars(product.sale_price_cents),
          "talking_points_md" => product.talking_points_md
        }

        form = to_form(Product.changeset(product, changes))

        socket
        |> assign(:editing_product, product)
        |> assign(:product_edit_form, form)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:generation_failed, generation, _reason}, socket) do
    # Only show banner for batch (session-wide) generation failures
    socket =
      if generation.session_id do
        socket
        |> assign(:current_generation, generation)
        |> assign(:current_product_name, nil)
      else
        socket
      end
      |> assign(:generating_in_modal, false)

    {:noreply, socket}
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
      # Close expanded session on Escape by removing query param
      {:noreply, push_patch(socket, to: ~p"/sessions")}
    end
  end

  @impl true
  def handle_event("toggle_expand", %{"session-id" => session_id}, socket) do
    session_id = normalize_id(session_id)
    current_expanded_id = socket.assigns.expanded_session_id

    # Build query params, preserving search query
    query_params =
      if current_expanded_id == session_id do
        # Collapsing - only preserve search
        if socket.assigns.session_search_query != "" do
          %{q: socket.assigns.session_search_query}
        else
          %{}
        end
      else
        # Expanding - preserve both search and session
        base_params = %{s: session_id}

        if socket.assigns.session_search_query != "" do
          Map.put(base_params, :q, socket.assigns.session_search_query)
        else
          base_params
        end
      end

    {:noreply, push_patch(socket, to: ~p"/sessions?#{query_params}")}
  end

  @impl true
  def handle_event("stop_propagation", _params, socket) do
    # No-op handler to prevent event bubbling to parent elements
    {:noreply, socket}
  end

  @impl true
  def handle_event("search_sessions", %{"value" => query}, socket) do
    # Mark search as touched (animations will be disabled from now on)
    socket = assign(socket, :search_touched, true)

    # Build query params, preserving expanded session and modal state
    query_params = %{}

    query_params =
      if query != "" do
        Map.put(query_params, :q, query)
      else
        query_params
      end

    query_params =
      if socket.assigns.expanded_session_id do
        Map.put(query_params, :s, socket.assigns.expanded_session_id)
      else
        query_params
      end

    query_params =
      if socket.assigns.show_new_session_modal do
        Map.put(query_params, :new, true)
      else
        query_params
      end

    {:noreply, push_patch(socket, to: ~p"/sessions?#{query_params}")}
  end

  @impl true
  def handle_event("load_more_sessions", _params, socket) do
    socket =
      socket
      |> assign(:loading_sessions, true)
      |> load_sessions(append: true)

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
    # Build URL with "new" param, preserving expanded session if any
    params = %{new: true}

    params =
      if socket.assigns.expanded_session_id do
        Map.put(params, :s, socket.assigns.expanded_session_id)
      else
        params
      end

    {:noreply, push_patch(socket, to: ~p"/sessions?#{params}")}
  end

  @impl true
  def handle_event("close_new_session_modal", _params, socket) do
    # Preserve expanded session in URL when closing new session modal
    path =
      case socket.assigns.expanded_session_id do
        nil -> ~p"/sessions"
        session_id -> ~p"/sessions?#{%{s: session_id}}"
      end

    socket =
      socket
      |> assign(:show_new_session_modal, false)
      |> assign(
        :session_form,
        to_form(Session.changeset(%Session{}, %{}))
      )
      |> push_patch(to: path)

    {:noreply, socket}
  end

  @impl true
  def handle_event("validate_session", %{"session" => params}, socket) do
    changeset =
      %Session{}
      |> Session.changeset(params)
      |> Map.put(:action, :validate)

    # Check for duplicate session name
    name = params["name"]
    brand_id = params["brand_id"]
    brand_id_int = if brand_id && brand_id != "", do: normalize_id(brand_id), else: nil

    changeset =
      if name && name != "" && brand_id_int && Sessions.session_name_exists?(name, brand_id_int) do
        Ecto.Changeset.add_error(changeset, :name, "already exists for this brand")
      else
        changeset
      end

    # Check if brand_id actually changed (normalize to strings for comparison)
    current_brand_id = get_in(socket.assigns.session_form.params, ["brand_id"]) |> to_string()
    new_brand_id = params["brand_id"] |> to_string()
    brand_changed = current_brand_id != new_brand_id

    socket = assign(socket, :session_form, to_form(changeset))

    # Only reload products if brand actually changed
    socket =
      if brand_changed do
        if new_brand_id && new_brand_id != "" do
          socket
          |> assign(:product_search_query, "")
          |> assign(:product_page, 1)
          |> assign(:selected_product_ids, MapSet.new())
          |> assign(:new_session_products_map, %{})
          |> load_products_for_new_session()
        else
          socket
          |> stream(:new_session_products, [], reset: true)
          |> assign(:new_session_has_more, false)
          |> assign(:product_search_query, "")
          |> assign(:product_total_count, 0)
          |> assign(:selected_product_ids, MapSet.new())
          |> assign(:new_session_products_map, %{})
        end
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("save_session", %{"session" => session_params}, socket) do
    # Generate slug from name
    slug = Sessions.slugify(session_params["name"])
    session_params = Map.put(session_params, "slug", slug)

    # Extract selected product IDs (as list in order)
    selected_ids = MapSet.to_list(socket.assigns.selected_product_ids)

    case Sessions.create_session_with_products(session_params, selected_ids) do
      {:ok, _created_session} ->
        # Preserve expanded state across reload (or expand the newly created session)
        expanded_id = socket.assigns.expanded_session_id

        # Remove "new" param from URL, preserve expanded session if any
        path =
          case expanded_id do
            nil -> ~p"/sessions"
            session_id -> ~p"/sessions?#{%{s: session_id}}"
          end

        socket =
          socket
          |> reload_sessions()
          |> assign(:show_new_session_modal, false)
          |> assign(
            :session_form,
            to_form(Session.changeset(%Session{}, %{}))
          )
          |> assign(:product_search_query, "")
          |> assign(:product_page, 1)
          |> assign(:selected_product_ids, MapSet.new())
          |> stream(:new_session_products, [], reset: true)
          |> assign(:new_session_has_more, false)
          |> push_patch(to: path)
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
        socket =
          socket
          |> reload_sessions()
          |> assign(:selected_session_for_product, nil)
          |> assign(:show_modal_for_session, nil)
          |> assign(:add_product_search_query, "")
          |> assign(:add_product_page, 1)
          |> assign(:add_product_selected_ids, MapSet.new())
          |> stream(:add_product_products, [], reset: true)
          |> assign(:add_product_has_more, false)
          |> put_flash(:info, "#{Enum.count(selected_ids)} product(s) added to session")

        {:noreply, socket}

      {:partial, added, skipped} ->
        socket =
          socket
          |> reload_sessions()
          |> assign(:selected_session_for_product, nil)
          |> assign(:show_modal_for_session, nil)
          |> assign(:add_product_search_query, "")
          |> assign(:add_product_page, 1)
          |> assign(:add_product_selected_ids, MapSet.new())
          |> stream(:add_product_products, [], reset: true)
          |> assign(:add_product_has_more, false)
          |> put_flash(:warning, "Added #{added} product(s). #{skipped} already in session (skipped).")

        {:noreply, socket}

      {:error, reason} ->
        socket =
          socket
          |> put_flash(:error, reason)

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("search_add_products", %{"value" => query}, socket) do
    # Detect if input looks like product IDs (contains commas or is numeric-like)
    if looks_like_product_ids?(query) do
      # ID-based lookup mode - show products but don't select yet
      brand_id =
        if socket.assigns.selected_session_for_product do
          socket.assigns.selected_session_for_product.brand_id
        end

      socket =
        socket
        |> assign(:add_product_search_query, query)
        |> display_products_by_id(
          query,
          brand_id,
          :add_product_selected_ids,
          :add_product_products,
          :add_product_products_map,
          :add_product_total_count
        )

      {:noreply, socket}
    else
      # Normal text search mode
      socket =
        socket
        |> assign(:add_product_search_query, query)
        |> assign(:add_product_page, 1)
        |> assign(:loading_add_products, true)
        |> load_products_for_add_modal()

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("search_add_products_submit", %{"value" => query}, socket) do
    # Detect if input looks like product IDs (contains commas or is numeric-like)
    if looks_like_product_ids?(query) do
      # ID-based lookup mode - select all displayed products
      socket = select_all_displayed_products(
        socket,
        :add_product_selected_ids,
        :add_product_products,
        :add_product_products_map
      )

      {:noreply, socket}
    else
      # Normal text search mode - auto-select if single result
      socket = maybe_auto_select_single_product(socket, :add_product_products_map, :add_product_selected_ids, :add_product_products)

      {:noreply, socket}
    end
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
        updated_product =
          Map.put(product, :selected, MapSet.member?(new_selected_ids, product_id))

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
        socket =
          socket
          |> reload_sessions()
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

  def handle_event(
        "reorder_products",
        %{"session_id" => session_id, "product_ids" => product_ids},
        socket
      ) do
    session_id = normalize_id(session_id)

    # Convert product IDs to integers
    product_ids = Enum.map(product_ids, &normalize_id/1)

    # Update positions in database
    case Sessions.reorder_products(session_id, product_ids) do
      {:ok, _count} ->
        socket = reload_sessions(socket)
        {:noreply, socket}

      {:error, reason} ->
        socket
        |> put_flash(:error, "Failed to reorder products: #{inspect(reason)}")
        |> then(&{:noreply, &1})
    end
  end

  def handle_event("delete_session", %{"session-id" => session_id}, socket) do
    session_id = normalize_id(session_id)
    session = Sessions.get_session!(session_id)

    case Sessions.delete_session(session) do
      {:ok, _session} ->
        # Clear expanded state if deleting the expanded session
        expanded_id =
          if socket.assigns.expanded_session_id == session_id,
            do: nil,
            else: socket.assigns.expanded_session_id

        # Update URL based on whether we cleared the expanded session
        path =
          case expanded_id do
            nil -> ~p"/sessions"
            id -> ~p"/sessions?#{%{s: id}}"
          end

        socket =
          socket
          |> assign(:expanded_session_id, expanded_id)
          |> reload_sessions()
          |> push_patch(to: path)
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
  def handle_event("duplicate_session", %{"session-id" => session_id}, socket) do
    session_id = normalize_id(session_id)

    case Sessions.duplicate_session(session_id) do
      {:ok, new_session} ->
        # Build URL to expand the newly created session
        path = ~p"/sessions?#{%{s: new_session.id}}"

        # Prepare edit modal for the duplicated session
        changeset = Session.changeset(new_session, %{})

        socket =
          socket
          |> assign(:expanded_session_id, new_session.id)
          |> reload_sessions()
          |> assign(:editing_session, new_session)
          |> assign(:session_edit_form, to_form(changeset))
          |> push_patch(to: path)
          |> put_flash(:info, "Session duplicated successfully")

        {:noreply, socket}

      {:error, _changeset} ->
        socket =
          socket
          |> put_flash(:error, "Failed to duplicate session")

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("copy_product_ids", %{"session-id" => session_id}, socket) do
    session_id = normalize_id(session_id)

    # Find the session in the loaded sessions list
    session = Enum.find(socket.assigns.sessions, &(&1.id == session_id))

    if session && session.session_products do
      # Extract product IDs from session products, in order
      # Prefer TikTok ID, fall back to Shopify numeric ID
      product_ids =
        session.session_products
        |> Enum.sort_by(& &1.position)
        |> Enum.map(&get_best_product_id(&1.product))
        |> Enum.reject(&is_nil/1)
        |> Enum.join(", ")

      if product_ids == "" do
        {:noreply, put_flash(socket, :error, "No product IDs found in this session")}
      else
        socket =
          socket
          |> push_event("copy", %{text: product_ids})
          |> put_flash(:info, "Product IDs copied to clipboard")

        {:noreply, socket}
      end
    else
      {:noreply, put_flash(socket, :error, "Session not found")}
    end
  end

  @impl true
  def handle_event("product_id_copied", _params, socket) do
    {:noreply, put_flash(socket, :info, "Product ID copied to clipboard")}
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
      |> assign(:current_image_index, 0)
      |> assign(:product_edit_form, to_form(changeset))

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_edit_product_modal", _params, socket) do
    socket =
      socket
      |> assign(:editing_product, nil)
      |> assign(:current_image_index, 0)
      |> assign(:product_edit_form, to_form(Product.changeset(%Product{}, %{})))

    {:noreply, socket}
  end

  @impl true
  def handle_event("next_image", _params, socket) do
    if socket.assigns.editing_product do
      images = socket.assigns.editing_product.product_images || []
      current_index = socket.assigns.current_image_index
      max_index = length(images) - 1

      new_index = if current_index >= max_index, do: 0, else: current_index + 1

      {:noreply, assign(socket, :current_image_index, new_index)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("previous_image", _params, socket) do
    if socket.assigns.editing_product do
      images = socket.assigns.editing_product.product_images || []
      current_index = socket.assigns.current_image_index
      max_index = length(images) - 1

      new_index = if current_index <= 0, do: max_index, else: current_index - 1

      {:noreply, assign(socket, :current_image_index, new_index)}
    else
      {:noreply, socket}
    end
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
    # Preserve expanded session in URL when closing edit modal
    path =
      case socket.assigns.expanded_session_id do
        nil -> ~p"/sessions"
        session_id -> ~p"/sessions?#{%{s: session_id}}"
      end

    socket =
      socket
      |> assign(:editing_session, nil)
      |> assign(:session_edit_form, to_form(Session.changeset(%Session{}, %{})))
      |> push_patch(to: path)

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
    slug = Sessions.slugify(session_params["name"])
    session_params = Map.put(session_params, "slug", slug)

    case Sessions.update_session(socket.assigns.editing_session, session_params) do
      {:ok, _session} ->
        socket =
          socket
          |> reload_sessions()
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
        socket =
          socket
          |> reload_sessions()
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
    # Detect if input looks like product IDs (contains commas or is numeric-like)
    if looks_like_product_ids?(query) do
      # ID-based lookup mode - show products but don't select yet
      brand_id = get_in(socket.assigns.session_form.params, ["brand_id"])
      brand_id = if brand_id && brand_id != "", do: normalize_id(brand_id), else: nil

      socket =
        socket
        |> assign(:product_search_query, query)
        |> display_products_by_id(
          query,
          brand_id,
          :selected_product_ids,
          :new_session_products,
          :new_session_products_map,
          :product_total_count
        )

      {:noreply, socket}
    else
      # Normal text search mode
      socket =
        socket
        |> assign(:product_search_query, query)
        |> assign(:product_page, 1)
        |> assign(:loading_products, true)
        |> load_products_for_new_session()

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("search_products_submit", %{"value" => query}, socket) do
    # Detect if input looks like product IDs (contains commas or is numeric-like)
    if looks_like_product_ids?(query) do
      # ID-based lookup mode - select all displayed products
      socket = select_all_displayed_products(
        socket,
        :selected_product_ids,
        :new_session_products,
        :new_session_products_map
      )

      {:noreply, socket}
    else
      # Normal text search mode - auto-select if single result
      socket = maybe_auto_select_single_product(socket, :new_session_products_map, :selected_product_ids, :new_session_products)

      {:noreply, socket}
    end
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
        updated_product =
          Map.put(product, :selected, MapSet.member?(new_selected_ids, product_id))

        stream_insert(socket, :new_session_products, updated_product)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("generate_session_talking_points", %{"session-id" => session_id}, socket) do
    session_id = normalize_id(session_id)

    case AI.generate_session_talking_points_async(session_id) do
      {:ok, _generation} ->
        # The handle_info callbacks will handle the UI updates
        {:noreply, socket}

      {:error, reason} ->
        socket =
          socket
          |> put_flash(:error, "Failed to start generation: #{reason}")

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("generate_product_talking_points", %{"product-id" => product_id}, socket) do
    product_id = String.to_integer(product_id)

    case AI.generate_talking_points_async(product_id) do
      {:ok, _generation} ->
        socket =
          socket
          |> assign(:generating_in_modal, true)

        {:noreply, socket}

      {:error, reason} ->
        socket =
          socket
          |> put_flash(:error, "Failed to start generation: #{reason}")

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_generation_modal", _params, socket) do
    {:noreply, assign(socket, :show_generation_modal, false)}
  end

  # Helper functions

  # Reloads just one session in the list without a full database reload
  defp reload_single_session(socket, session_id) do
    sessions = socket.assigns.sessions

    # Find and reload just the affected session
    case Enum.find_index(sessions, &(&1.id == session_id)) do
      nil ->
        # Session not in the current list, do nothing
        socket

      index ->
        # Reload only this session from the database
        updated_session = Sessions.get_session!(session_id)

        # Replace the session in the list
        updated_sessions = List.replace_at(sessions, index, updated_session)

        assign(socket, :sessions, updated_sessions)
    end
  end

  # Template helper to get primary image from product
  def primary_image(product) do
    product.product_images
    |> Enum.find(& &1.is_primary)
    |> case do
      nil -> List.first(product.product_images)
      image -> image
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
          brand_id = normalize_id(brand_id_str)

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

              Map.put(
                product_with_image,
                :selected,
                MapSet.member?(socket.assigns.selected_product_ids, product.id)
              )
            end)

          # Build a map for quick lookup by product ID
          products_map =
            if append do
              socket.assigns.new_session_products_map
            else
              %{}
            end
            |> Map.merge(Map.new(products_with_state, &{&1.id, &1}))

          socket
          |> assign(:loading_products, false)
          |> assign(:new_session_products_map, products_map)
          |> stream(:new_session_products, products_with_state,
            reset: !append,
            at: if(append, do: -1, else: 0)
          )
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

  defp normalize_id(id) when is_integer(id), do: id
  defp normalize_id(id) when is_binary(id), do: String.to_integer(id)

  defp apply_url_params(socket, params) do
    socket
    |> apply_search_params(params)
    |> maybe_expand_session(params["s"])
    |> maybe_show_new_session_modal(params["new"])
  end

  defp apply_search_params(socket, params) do
    search_query = params["q"] || ""

    # Only reload if search query changed
    if socket.assigns.session_search_query != search_query do
      socket
      |> assign(:session_search_query, search_query)
      |> assign(:session_page, 1)
      |> assign(:loading_sessions, true)
      |> load_sessions()
    else
      socket
    end
  end

  defp maybe_expand_session(socket, nil), do: assign(socket, :expanded_session_id, nil)

  defp maybe_expand_session(socket, session_id_str) do
    session_id = normalize_id(session_id_str)
    # Verify session exists before expanding
    if Enum.any?(socket.assigns.sessions, &(&1.id == session_id)) do
      socket
      |> assign(:expanded_session_id, session_id)
      |> push_event("scroll-to-session", %{session_id: session_id})
    else
      # Session not found, ignore param
      assign(socket, :expanded_session_id, nil)
    end
  rescue
    ArgumentError ->
      # Invalid ID format, ignore param
      assign(socket, :expanded_session_id, nil)
  end

  defp maybe_show_new_session_modal(socket, nil), do: socket

  defp maybe_show_new_session_modal(socket, _value) do
    # "new" param exists (any value), show the new session modal and initialize state
    # Always use PAVOI brand
    pavoi_brand = Catalog.get_brand_by_name("PAVOI")
    brand_id = if pavoi_brand, do: pavoi_brand.id, else: nil

    # Initialize session form with brand_id pre-set
    session_form =
      to_form(Session.changeset(%Session{}, %{"brand_id" => brand_id}))

    socket
    |> assign(:show_new_session_modal, true)
    |> assign(:session_form, session_form)
    |> assign(:product_search_query, "")
    |> assign(:product_page, 1)
    |> assign(:selected_product_ids, MapSet.new())
    |> stream(:new_session_products, [], reset: true)
    |> assign(:new_session_has_more, false)
    |> load_products_for_new_session()
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

              Map.put(
                product_with_image,
                :selected,
                MapSet.member?(socket.assigns.add_product_selected_ids, product.id)
              )
            end)

          # Build a map for quick lookup by product ID
          products_map =
            if append do
              socket.assigns.add_product_products_map
            else
              %{}
            end
            |> Map.merge(Map.new(products_with_state, &{&1.id, &1}))

          socket
          |> assign(:loading_add_products, false)
          |> assign(:add_product_products_map, products_map)
          |> stream(:add_product_products, products_with_state,
            reset: !append,
            at: if(append, do: -1, else: 0)
          )
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

    # Count successes and failures
    successes = Enum.count(results, fn result -> match?({:ok, _}, result) end)
    failures = length(results) - successes

    cond do
      failures == 0 ->
        :ok

      successes > 0 ->
        # Some succeeded, some failed (likely duplicates)
        {:partial, successes, failures}

      true ->
        # All failed
        {:error, "Could not add products (they may already be in this session)"}
    end
  end

  defp find_product_in_stream(products_map, product_id) do
    Map.get(products_map, product_id)
  end

  # Get the best product ID for clipboard copy - prefer TikTok, fall back to Shopify numeric
  defp get_best_product_id(product) do
    cond do
      product.tiktok_product_id && product.tiktok_product_id != "" ->
        product.tiktok_product_id

      product.pid && product.pid != "" ->
        # Extract numeric ID from Shopify GID like "gid://shopify/Product/8772010639613"
        # Uses extract_shopify_numeric_id/1 imported from ViewHelpers
        extract_shopify_numeric_id(product.pid)

      true ->
        nil
    end
  end

  # Detect if input looks like product IDs rather than a text search
  # Returns true if input contains commas OR is a single numeric-like value (digits only, 10+ chars for TikTok IDs)
  defp looks_like_product_ids?(input) do
    trimmed = String.trim(input)

    cond do
      # Empty input is not IDs
      trimmed == "" -> false
      # Contains commas = multiple IDs
      String.contains?(trimmed, ",") -> true
      # Single numeric string (likely TikTok or Shopify ID)
      Regex.match?(~r/^\d{6,}$/, trimmed) -> true
      # Otherwise treat as text search
      true -> false
    end
  end

  # Display products by ID without selecting them (called on input change)
  # Shows found products in the grid, preserving existing selections
  defp display_products_by_id(socket, ids_input, brand_id, selected_ids_key, stream_key, products_map_key, total_count_key) do
    # Parse input: split by comma, newline, or whitespace
    product_ids =
      ids_input
      |> String.split(~r/[\s,]+/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if Enum.empty?(product_ids) do
      socket
    else
      opts = if brand_id, do: [brand_id: brand_id], else: []
      {found_products, _not_found_ids} = Catalog.find_products_by_ids(product_ids, opts)

      # Get current selections to preserve selected state for already-selected items
      current_selected = socket.assigns[selected_ids_key]

      # Prepare products with primary_image and preserve existing selection state
      products_with_state =
        found_products
        |> Enum.map(fn p ->
          p
          |> add_primary_image()
          |> Map.put(:selected, MapSet.member?(current_selected, p.id))
        end)

      # Build new products map from found products
      new_products_map = Map.new(products_with_state, &{&1.id, &1})

      # Reset stream with found products and update all related state
      socket
      |> assign(products_map_key, new_products_map)
      |> assign(total_count_key, length(found_products))
      |> stream(stream_key, products_with_state, reset: true)
    end
  end

  # Select all products currently displayed in the grid (called on Enter)
  # Shows flash feedback about what was found/selected
  defp select_all_displayed_products(socket, selected_ids_key, stream_key, products_map_key) do
    products_map = socket.assigns[products_map_key]

    if map_size(products_map) == 0 do
      socket
    else
      # Get all product IDs from the current display
      displayed_product_ids = Map.keys(products_map) |> MapSet.new()

      # Merge into current selection
      current_selected = socket.assigns[selected_ids_key]
      new_selected = MapSet.union(current_selected, displayed_product_ids)

      # Update all products in the map to selected state
      updated_products_map =
        Map.new(products_map, fn {id, product} ->
          {id, Map.put(product, :selected, true)}
        end)

      # Update the stream with selected state
      socket =
        Enum.reduce(updated_products_map, socket, fn {_id, product}, acc_socket ->
          stream_insert(acc_socket, stream_key, product)
        end)

      # Count for feedback
      newly_selected = MapSet.size(displayed_product_ids) - MapSet.size(MapSet.intersection(current_selected, displayed_product_ids))
      total_displayed = map_size(products_map)

      socket =
        socket
        |> assign(selected_ids_key, new_selected)
        |> assign(products_map_key, updated_products_map)

      # Show feedback
      cond do
        newly_selected == 0 ->
          put_flash(socket, :info, "#{total_displayed} product(s) already selected")

        newly_selected == total_displayed && total_displayed == 1 ->
          put_flash(socket, :info, "Product selected")

        newly_selected == total_displayed ->
          put_flash(socket, :info, "#{total_displayed} product(s) selected")

        true ->
          put_flash(socket, :info, "#{newly_selected} new product(s) selected (#{total_displayed - newly_selected} already selected)")
        end

      socket
    end
  end

  # Auto-select a single product if there's exactly one result in the products map
  defp maybe_auto_select_single_product(socket, products_map_key, selected_ids_key, stream_key) do
    products_map = socket.assigns[products_map_key]

    if map_size(products_map) == 1 do
      # Get the single product
      [{product_id, product}] = Map.to_list(products_map)

      # Only select if not already selected
      selected_ids = socket.assigns[selected_ids_key]

      if MapSet.member?(selected_ids, product_id) do
        socket
      else
        new_selected_ids = MapSet.put(selected_ids, product_id)
        updated_product = Map.put(product, :selected, true)

        socket
        |> assign(selected_ids_key, new_selected_ids)
        |> stream_insert(stream_key, updated_product)
      end
    else
      socket
    end
  end

  # Loads sessions for the sessions list with pagination support.
  # Supports both initial load and appending additional pages.
  defp load_sessions(socket, opts \\ []) do
    append = Keyword.get(opts, :append, false)
    page = if append, do: socket.assigns.session_page + 1, else: 1
    search_query = socket.assigns.session_search_query

    result =
      Sessions.list_sessions_with_details_paginated(
        page: page,
        per_page: 20,
        search_query: search_query
      )

    # When appending, concatenate with existing sessions
    sessions =
      if append do
        socket.assigns.sessions ++ result.sessions
      else
        result.sessions
      end

    socket
    |> assign(:loading_sessions, false)
    |> assign(:sessions, sessions)
    |> assign(:session_page, result.page)
    |> assign(:sessions_has_more, result.has_more)
  end

  # Helper to reload sessions from page 1 (used after modifications)
  defp reload_sessions(socket) do
    socket
    |> assign(:session_page, 1)
    |> load_sessions()
  end
end
