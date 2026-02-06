defmodule PavoiWeb.ProductSetsLive.Index do
  @moduledoc """
  Live view for managing sessions and their products.

  ## Stream + LiveComponent Pattern

  This module uses Phoenix LiveView streams for rendering product grids with live components
  for items that have dynamic state. The pattern is simple:

  ### Key Components:
  - `:new_product_set_products` stream - contains products for the "New Session" modal
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
  alias Pavoi.ProductSets
  alias Pavoi.ProductSets.{ProductSet, ProductSetProduct}
  alias Pavoi.Settings
  alias Pavoi.Storage
  alias Pavoi.Workers.ShopifySyncWorker
  alias Pavoi.Workers.TiktokSyncWorker
  alias PavoiWeb.BrandRoutes

  import PavoiWeb.AIComponents
  import PavoiWeb.ProductComponents
  import PavoiWeb.ViewHelpers

  @impl true
  def mount(_params, _session, socket) do
    brand = socket.assigns.current_brand
    brand_id = brand.id

    # Subscribe to session list changes for real-time updates across tabs
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Pavoi.PubSub, "product_sets:#{brand_id}:list")
      Phoenix.PubSub.subscribe(Pavoi.PubSub, "shopify:sync:#{brand_id}")
      Phoenix.PubSub.subscribe(Pavoi.PubSub, "tiktok:sync:#{brand_id}")
      Phoenix.PubSub.subscribe(Pavoi.PubSub, "ai:talking_points:#{brand_id}")
    end

    brands = socket.assigns.user_brands |> Enum.map(& &1.brand)
    last_sync_at = Settings.get_shopify_last_sync_at(brand_id)
    tiktok_last_sync_at = Settings.get_tiktok_last_sync_at(brand_id)

    # Check if syncs are currently in progress
    shopify_syncing = sync_job_active?(ShopifySyncWorker, brand_id)
    tiktok_syncing = sync_job_active?(TiktokSyncWorker, brand_id)

    socket =
      socket
      # Page tab state (sets vs products)
      |> assign(:page_tab, "sets")
      |> assign(:brand_id, brand_id)
      # Product Sets tab state
      |> assign(:product_set_page, 1)
      |> assign(:product_sets_has_more, false)
      |> assign(:loading_product_sets, false)
      |> assign(:product_sets, [])
      |> assign(:product_set_search_query, "")
      |> assign(:search_touched, false)
      |> assign(:lightbox_open, false)
      |> assign(:brands, brands)
      |> load_product_sets()
      |> assign(:expanded_product_set_id, nil)
      |> assign(:selected_product_set_for_product, nil)
      |> assign(:available_products, [])
      |> assign(:show_modal_for_product_set, nil)
      |> assign(:show_new_product_set_modal, false)
      |> assign(:editing_product, nil)
      |> assign(:current_image_index, 0)
      |> assign(:generating_in_modal, false)
      |> assign(
        :product_form,
        to_form(ProductSetProduct.changeset(%ProductSetProduct{}, %{}))
      )
      |> assign(
        :product_set_form,
        to_form(ProductSet.changeset(%ProductSet{brand_id: brand_id}, %{}))
      )
      |> assign(
        :product_edit_form,
        to_form(Product.changeset(%Product{}, %{}))
      )
      |> assign(:editing_product_set, nil)
      |> assign(
        :product_set_edit_form,
        to_form(ProductSet.changeset(%ProductSet{brand_id: brand_id}, %{}))
      )
      |> assign(:product_search_query, "")
      |> assign(:product_page, 1)
      |> assign(:product_total_count, 0)
      |> assign(:selected_product_ids, MapSet.new())
      |> assign(:selected_product_order, [])
      |> assign(:new_product_set_has_more, false)
      |> assign(:loading_products, false)
      |> assign(:new_product_set_products_map, %{})
      |> assign(:new_session_display_order, [])
      |> assign(:show_product_enter_hint, false)
      |> stream(:new_product_set_products, [])
      |> assign(:add_product_search_query, "")
      |> assign(:add_product_page, 1)
      |> assign(:add_product_total_count, 0)
      |> assign(:add_product_selected_ids, MapSet.new())
      |> assign(:add_product_selected_order, [])
      |> assign(:add_product_has_more, false)
      |> assign(:loading_add_products, false)
      |> assign(:add_product_products_map, %{})
      |> assign(:add_product_display_order, [])
      |> assign(:show_add_product_enter_hint, false)
      |> stream(:add_product_products, [])
      |> assign(:current_generation, nil)
      |> assign(:current_product_name, nil)
      |> assign(:show_generation_modal, false)
      |> assign(:share_product_set_id, nil)
      |> assign(:share_url, nil)
      |> assign(:share_url_copied, false)
      # Undo history for product set operations (session-scoped)
      |> assign(:undo_history, %{})
      |> allow_upload(:notes_image,
        accept: ~w(.jpg .jpeg .png .webp .gif),
        max_entries: 1,
        max_file_size: 5_000_000,
        external: &presign_notes_image/2
      )
      # Products tab state (for browsing all products)
      |> assign(:last_sync_at, last_sync_at)
      |> assign(:syncing, shopify_syncing)
      |> assign(:tiktok_last_sync_at, tiktok_last_sync_at)
      |> assign(:tiktok_syncing, tiktok_syncing)
      |> assign(:platform_filter, "")
      |> assign(:browse_product_search_query, "")
      |> assign(:browse_product_sort_by, "")
      |> assign(:browse_product_page, 1)
      |> assign(:browse_products_total_count, 0)
      |> assign(:browse_products_has_more, false)
      |> assign(:loading_browse_products, false)
      |> assign(:browse_search_touched, false)
      |> assign(:generating_product_id, nil)
      |> stream(:browse_products, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> apply_page_tab(params)
      |> apply_url_params(params)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:product_set_list_changed}, socket) do
    # Reload product sets from database while preserving UI state
    # Reset pagination to page 1 and reload
    socket =
      socket
      |> assign(:product_set_page, 1)
      |> load_product_sets()

    {:noreply, socket}
  end

  @impl true
  def handle_info({:sync_started}, socket) do
    socket =
      socket
      |> assign(:syncing, true)
      |> put_flash(:info, "Syncing product catalog from Shopify...")

    {:noreply, socket}
  end

  @impl true
  def handle_info({:sync_completed, counts}, socket) do
    # Reload sessions to pick up any product changes
    # Reset pagination to page 1 and reload
    brand_id = socket.assigns.current_brand.id
    last_sync_at = Settings.get_shopify_last_sync_at(brand_id)

    socket =
      socket
      |> assign(:syncing, false)
      |> assign(:last_sync_at, last_sync_at)
      |> assign(:product_set_page, 1)
      |> load_product_sets()
      |> maybe_reload_browse_products()
      |> put_flash(
        :info,
        "Shopify sync complete: #{counts.products} products, #{counts.images} images"
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
      |> assign(:syncing, false)
      |> put_flash(:error, message)

    {:noreply, socket}
  end

  # TikTok sync event handlers
  @impl true
  def handle_info({:tiktok_sync_started}, socket) do
    socket =
      socket
      |> assign(:tiktok_syncing, true)
      |> put_flash(:info, "Syncing product catalog from TikTok Shop...")

    {:noreply, socket}
  end

  @impl true
  def handle_info({:tiktok_sync_completed, _counts}, socket) do
    brand_id = socket.assigns.current_brand.id
    tiktok_last_sync_at = Settings.get_tiktok_last_sync_at(brand_id)

    socket =
      socket
      |> assign(:tiktok_syncing, false)
      |> assign(:tiktok_last_sync_at, tiktok_last_sync_at)
      |> assign(:product_set_page, 1)
      |> load_product_sets()
      |> maybe_reload_browse_products()
      |> put_flash(:info, "TikTok sync completed successfully")

    {:noreply, socket}
  end

  @impl true
  def handle_info({:tiktok_sync_failed, reason}, socket) do
    message = "TikTok sync failed: #{inspect(reason)}"

    socket =
      socket
      |> assign(:tiktok_syncing, false)
      |> put_flash(:error, message)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:generation_started, generation}, socket) do
    # Only show banner for batch (session-wide) generation
    socket =
      if generation.product_set_id do
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
      if generation.product_set_id do
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
      if generation.product_set_id do
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
      if generation.product_set_id do
        # Reload just the affected session, not all sessions
        reload_single_product_set(socket, generation.product_set_id)
      else
        socket
      end

    # If a product modal is currently open, refresh it with updated talking points
    socket =
      if socket.assigns.editing_product do
        product =
          Catalog.get_product_with_images!(
            socket.assigns.brand_id,
            socket.assigns.editing_product.id
          )

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
      if generation.product_set_id do
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
  def handle_event("escape_pressed", _params, socket) do
    # Only close expanded product sets if no modal is currently open
    # If a modal is open, let the modal's own Escape handler close it first
    modal_open? =
      socket.assigns.show_new_product_set_modal or
        socket.assigns.selected_product_set_for_product != nil or
        socket.assigns.editing_product != nil or socket.assigns.editing_product_set != nil

    if modal_open? do
      {:noreply, socket}
    else
      # Close expanded product set on Escape by removing query param
      {:noreply, push_patch(socket, to: product_sets_path(socket))}
    end
  end

  @impl true
  def handle_event("toggle_expand", %{"product-set-id" => session_id}, socket) do
    session_id = normalize_id(session_id)
    current_expanded_id = socket.assigns.expanded_product_set_id

    # Build query params, preserving search query
    query_params =
      if current_expanded_id == session_id do
        # Collapsing - only preserve search
        if socket.assigns.product_set_search_query != "" do
          %{q: socket.assigns.product_set_search_query}
        else
          %{}
        end
      else
        # Expanding - preserve both search and session
        base_params = %{s: session_id}

        if socket.assigns.product_set_search_query != "" do
          Map.put(base_params, :q, socket.assigns.product_set_search_query)
        else
          base_params
        end
      end

    {:noreply, push_patch(socket, to: product_sets_path(socket, query_params))}
  end

  @impl true
  def handle_event("stop_propagation", _params, socket) do
    # No-op handler to prevent event bubbling to parent elements
    {:noreply, socket}
  end

  @impl true
  def handle_event("close_lightbox", _params, socket) do
    {:noreply, assign(socket, :lightbox_open, false)}
  end

  @impl true
  def handle_event("search_product_sets", %{"value" => query}, socket) do
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
      if socket.assigns.expanded_product_set_id do
        Map.put(query_params, :s, socket.assigns.expanded_product_set_id)
      else
        query_params
      end

    query_params =
      if socket.assigns.show_new_product_set_modal do
        Map.put(query_params, :new, true)
      else
        query_params
      end

    {:noreply, push_patch(socket, to: product_sets_path(socket, query_params))}
  end

  @impl true
  def handle_event("load_more_product_sets", _params, socket) do
    socket =
      socket
      |> assign(:loading_product_sets, true)
      |> load_product_sets(append: true)

    {:noreply, socket}
  end

  @impl true
  def handle_event("load_products_for_product_set", %{"product-set-id" => session_id}, socket) do
    session_id = normalize_id(session_id)
    session = Enum.find(socket.assigns.product_sets, &(&1.id == session_id))

    socket =
      socket
      |> assign(:selected_product_set_for_product, session)
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
  def handle_event("validate_product", %{"product_set_product" => params}, socket) do
    changeset =
      %ProductSetProduct{}
      |> ProductSetProduct.changeset(params)
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
      |> assign(:selected_product_set_for_product, nil)
      |> assign(:show_modal_for_product_set, nil)
      |> assign(
        :product_form,
        to_form(ProductSetProduct.changeset(%ProductSetProduct{}, %{}))
      )
      |> assign(:add_product_search_query, "")
      |> assign(:add_product_page, 1)
      |> assign(:add_product_selected_ids, MapSet.new())
      |> assign(:add_product_selected_order, [])
      |> assign(:add_product_display_order, [])
      |> stream(:add_product_products, [], reset: true)
      |> assign(:add_product_has_more, false)
      |> assign(:loading_add_products, false)

    {:noreply, socket}
  end

  @impl true
  def handle_event("show_new_product_set_modal", _params, socket) do
    # Build URL with "new" param, preserving expanded session if any
    params = %{new: true}

    params =
      if socket.assigns.expanded_product_set_id do
        Map.put(params, :s, socket.assigns.expanded_product_set_id)
      else
        params
      end

    {:noreply, push_patch(socket, to: product_sets_path(socket, params))}
  end

  @impl true
  def handle_event("close_new_product_set_modal", _params, socket) do
    # Preserve expanded session in URL when closing new session modal
    path =
      case socket.assigns.expanded_product_set_id do
        nil -> product_sets_path(socket)
        session_id -> product_sets_path(socket, %{s: session_id})
      end

    socket =
      socket
      |> assign(:show_new_product_set_modal, false)
      |> assign(
        :product_set_form,
        to_form(ProductSet.changeset(%ProductSet{brand_id: socket.assigns.brand_id}, %{}))
      )
      |> push_patch(to: path)

    {:noreply, socket}
  end

  @impl true
  def handle_event("validate_product_set", %{"product_set" => params}, socket) do
    changeset =
      %ProductSet{}
      |> ProductSet.changeset(params)
      |> Map.put(:action, :validate)

    # Check for duplicate session name
    name = params["name"]
    brand_id = socket.assigns.brand_id

    changeset =
      if name && name != "" && ProductSets.product_set_name_exists?(name, brand_id) do
        Ecto.Changeset.add_error(changeset, :name, "already exists for this brand")
      else
        changeset
      end

    {:noreply, assign(socket, :product_set_form, to_form(changeset))}
  end

  @impl true
  def handle_event("save_product_set", %{"product_set" => product_set_params}, socket) do
    # Generate slug from name
    slug = ProductSets.slugify(product_set_params["name"])
    product_set_params = Map.put(product_set_params, "slug", slug)

    # Handle image upload - consume uploaded entries and get the key
    # For external uploads, the metadata from presign function is the first arg
    # We store just the key, not a URL, since we need to generate presigned URLs for display
    image_key =
      consume_uploaded_entries(socket, :notes_image, fn meta, _entry ->
        {:ok, meta.key}
      end)
      |> List.first()

    product_set_params =
      if image_key do
        Map.put(product_set_params, "notes_image_url", image_key)
      else
        product_set_params
      end

    # Extract selected product IDs in order (preserves paste/selection order)
    selected_ids = socket.assigns.selected_product_order

    case ProductSets.create_product_set_with_products(
           socket.assigns.brand_id,
           product_set_params,
           selected_ids
         ) do
      {:ok, _created_session} ->
        # Preserve expanded state across reload (or expand the newly created session)
        expanded_id = socket.assigns.expanded_product_set_id

        # Remove "new" param from URL, preserve expanded session if any
        path =
          case expanded_id do
            nil -> product_sets_path(socket)
            session_id -> product_sets_path(socket, %{s: session_id})
          end

        socket =
          socket
          |> reload_product_sets()
          |> assign(:show_new_product_set_modal, false)
          |> assign(
            :product_set_form,
            to_form(ProductSet.changeset(%ProductSet{brand_id: socket.assigns.brand_id}, %{}))
          )
          |> assign(:product_search_query, "")
          |> assign(:product_page, 1)
          |> assign(:selected_product_ids, MapSet.new())
          |> assign(:selected_product_order, [])
          |> assign(:new_session_display_order, [])
          |> stream(:new_product_set_products, [], reset: true)
          |> assign(:new_product_set_has_more, false)
          |> push_patch(to: path)
          |> put_flash(:info, "Product set created successfully")

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        socket =
          socket
          |> assign(:product_set_form, to_form(changeset))
          |> put_flash(:error, "Please fix the errors below")

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save_products_to_product_set", _params, socket) do
    session_id = socket.assigns.selected_product_set_for_product.id
    # Use order list to preserve paste/selection order
    selected_ids = socket.assigns.add_product_selected_order

    # Add each product to the end of the queue
    case add_products_to_product_set(session_id, selected_ids) do
      {:ok, created_psp_ids} ->
        # Record undo action with created PSP IDs
        undo_action = %{type: :add_products, data: %{added_psp_ids: created_psp_ids}}

        socket =
          socket
          |> push_undo_action(session_id, undo_action)
          |> reload_product_sets()
          |> assign(:selected_product_set_for_product, nil)
          |> assign(:show_modal_for_product_set, nil)
          |> assign(:add_product_search_query, "")
          |> assign(:add_product_page, 1)
          |> assign(:add_product_selected_ids, MapSet.new())
          |> assign(:add_product_selected_order, [])
          |> assign(:add_product_display_order, [])
          |> stream(:add_product_products, [], reset: true)
          |> assign(:add_product_has_more, false)
          |> put_flash(:info, "#{Enum.count(selected_ids)} product(s) added to product set")

        {:noreply, socket}

      {:partial, added, skipped, created_psp_ids} ->
        # Record undo action with created PSP IDs (only the ones that succeeded)
        undo_action = %{type: :add_products, data: %{added_psp_ids: created_psp_ids}}

        socket =
          socket
          |> push_undo_action(session_id, undo_action)
          |> reload_product_sets()
          |> assign(:selected_product_set_for_product, nil)
          |> assign(:show_modal_for_product_set, nil)
          |> assign(:add_product_search_query, "")
          |> assign(:add_product_page, 1)
          |> assign(:add_product_selected_ids, MapSet.new())
          |> assign(:add_product_selected_order, [])
          |> assign(:add_product_display_order, [])
          |> stream(:add_product_products, [], reset: true)
          |> assign(:add_product_has_more, false)
          |> put_flash(
            :warning,
            "Added #{added} product(s). #{skipped} already in product set (skipped)."
          )

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
        if socket.assigns.selected_product_set_for_product do
          socket.assigns.selected_product_set_for_product.brand_id
        end

      socket =
        socket
        |> assign(:add_product_search_query, query)
        |> display_products_by_id(query, brand_id,
          selected_ids: :add_product_selected_ids,
          stream: :add_product_products,
          products_map: :add_product_products_map,
          total_count: :add_product_total_count,
          enter_hint: :show_add_product_enter_hint,
          display_order: :add_product_display_order
        )

      {:noreply, socket}
    else
      # Normal text search mode - hide the enter hint
      socket =
        socket
        |> assign(:add_product_search_query, query)
        |> assign(:add_product_page, 1)
        |> assign(:loading_add_products, true)
        |> assign(:show_add_product_enter_hint, false)
        |> load_products_for_add_modal()

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("search_add_products_submit", %{"value" => query}, socket) do
    # Detect if input looks like product IDs (contains commas or is numeric-like)
    if looks_like_product_ids?(query) do
      # ID-based lookup mode - select all displayed products
      socket =
        select_all_displayed_products(socket,
          selected_ids: :add_product_selected_ids,
          selected_order: :add_product_selected_order,
          stream: :add_product_products,
          products_map: :add_product_products_map,
          display_order: :add_product_display_order,
          enter_hint: :show_add_product_enter_hint
        )

      {:noreply, socket}
    else
      # Normal text search mode - auto-select if single result
      socket =
        maybe_auto_select_single_product(
          socket,
          :add_product_products_map,
          :add_product_selected_ids,
          :add_product_products
        )

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
    selected_order = socket.assigns.add_product_selected_order

    is_selecting = not MapSet.member?(selected_ids, product_id)

    new_selected_ids =
      if is_selecting do
        MapSet.put(selected_ids, product_id)
      else
        MapSet.delete(selected_ids, product_id)
      end

    # Maintain order: append when selecting, remove when deselecting
    new_selected_order =
      if is_selecting do
        selected_order ++ [product_id]
      else
        List.delete(selected_order, product_id)
      end

    # Find the product in the map and update it with the new selected state
    product = find_product_in_stream(socket.assigns.add_product_products_map, product_id)

    socket =
      socket
      |> assign(:add_product_selected_ids, new_selected_ids)
      |> assign(:add_product_selected_order, new_selected_order)

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
  def handle_event("remove_product", %{"product-set-product-id" => sp_id}, socket) do
    sp_id = normalize_id(sp_id)

    # Capture product data before deletion for undo
    psp_data = ProductSets.get_product_set_product_for_undo(sp_id)

    case ProductSets.remove_product_from_product_set(sp_id) do
      {:ok, _session_product} ->
        socket =
          if psp_data do
            # Record undo action with all data needed to restore
            undo_action = %{type: :remove_product, data: psp_data}
            push_undo_action(socket, psp_data.product_set_id, undo_action)
          else
            socket
          end

        socket =
          socket
          |> reload_product_sets()
          |> put_flash(:info, "Product removed from product set")

        {:noreply, socket}

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Product not found in product set")
        |> then(&{:noreply, &1})

      {:error, reason} ->
        socket
        |> put_flash(:error, "Failed to remove product: #{inspect(reason)}")
        |> then(&{:noreply, &1})
    end
  end

  def handle_event(
        "reorder_products",
        %{"product_set_id" => product_set_id, "product_ids" => product_ids},
        socket
      ) do
    product_set_id = normalize_id(product_set_id)

    # Capture current order before reordering for undo
    previous_order = ProductSets.get_current_product_order(product_set_id)

    # Convert product IDs to integers
    product_ids = Enum.map(product_ids, &normalize_id/1)

    # Update positions in database
    case ProductSets.reorder_products(product_set_id, product_ids) do
      {:ok, _count} ->
        # Record undo action with previous order
        undo_action = %{type: :reorder_products, data: %{previous_order: previous_order}}

        socket =
          socket
          |> push_undo_action(product_set_id, undo_action)
          |> reload_product_sets()

        {:noreply, socket}

      {:error, reason} ->
        socket
        |> put_flash(:error, "Failed to reorder products: #{inspect(reason)}")
        |> then(&{:noreply, &1})
    end
  end

  def handle_event("undo_product_set_action", %{"product-set-id" => product_set_id}, socket) do
    product_set_id = normalize_id(product_set_id)
    {action, socket} = pop_undo_action(socket, product_set_id)

    case execute_undo_action(action, product_set_id) do
      {:ok, message} ->
        socket =
          socket
          |> reload_product_sets()
          |> put_flash(:info, message)

        {:noreply, socket}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}

      :noop ->
        {:noreply, put_flash(socket, :info, "Nothing to undo")}
    end
  end

  def handle_event("delete_product_set", %{"product-set-id" => session_id}, socket) do
    session_id = normalize_id(session_id)
    session = ProductSets.get_product_set!(socket.assigns.brand_id, session_id)

    case ProductSets.delete_product_set(session) do
      {:ok, _session} ->
        # Clear expanded state if deleting the expanded session
        expanded_id =
          if socket.assigns.expanded_product_set_id == session_id,
            do: nil,
            else: socket.assigns.expanded_product_set_id

        # Update URL based on whether we cleared the expanded session
        path =
          case expanded_id do
            nil -> product_sets_path(socket)
            id -> product_sets_path(socket, %{s: id})
          end

        socket =
          socket
          |> assign(:expanded_product_set_id, expanded_id)
          |> reload_product_sets()
          |> push_patch(to: path)
          |> put_flash(:info, "Product set deleted successfully")

        {:noreply, socket}

      {:error, _changeset} ->
        socket =
          socket
          |> put_flash(:error, "Failed to delete product set")

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("duplicate_product_set", %{"product-set-id" => session_id}, socket) do
    session_id = normalize_id(session_id)

    case ProductSets.duplicate_product_set(socket.assigns.brand_id, session_id) do
      {:ok, new_product_set} ->
        # Build URL to expand the newly created session
        path = product_sets_path(socket, %{s: new_product_set.id})

        # Prepare edit modal for the duplicated session
        changeset = ProductSet.changeset(new_product_set, %{})

        socket =
          socket
          |> assign(:expanded_product_set_id, new_product_set.id)
          |> reload_product_sets()
          |> assign(:editing_product_set, new_product_set)
          |> assign(:product_set_edit_form, to_form(changeset))
          |> push_patch(to: path)
          |> put_flash(:info, "Product set duplicated successfully")

        {:noreply, socket}

      {:error, _changeset} ->
        socket =
          socket
          |> put_flash(:error, "Failed to duplicate product set")

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("copy_product_ids", %{"product-set-id" => session_id}, socket) do
    session_id = normalize_id(session_id)

    # Find the session in the loaded sessions list
    session = Enum.find(socket.assigns.product_sets, &(&1.id == session_id))

    if session && session.product_set_products do
      # Extract product IDs from session products, in order
      # Prefer TikTok ID, fall back to Shopify numeric ID
      product_ids =
        session.product_set_products
        |> Enum.sort_by(& &1.position)
        |> Enum.map(&get_best_product_id(&1.product))
        |> Enum.reject(&is_nil/1)
        |> Enum.join(", ")

      if product_ids == "" do
        {:noreply, put_flash(socket, :error, "No product IDs found in this product set")}
      else
        socket =
          socket
          |> push_event("copy", %{text: product_ids})
          |> put_flash(:info, "Product IDs copied to clipboard")

        {:noreply, socket}
      end
    else
      {:noreply, put_flash(socket, :error, "Product set not found")}
    end
  end

  @impl true
  def handle_event("product_id_copied", _params, socket) do
    {:noreply, put_flash(socket, :info, "Product ID copied to clipboard")}
  end

  @impl true
  def handle_event("show_edit_product_modal", %{"product-id" => product_id}, socket) do
    product = Catalog.get_product_with_images!(socket.assigns.brand_id, product_id)

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

    # If on products tab, push_patch to update URL (remove ?p= param)
    socket =
      if socket.assigns.page_tab == "products" do
        query_params =
          %{pt: "products"}
          |> maybe_add_param(:q, socket.assigns.browse_product_search_query)
          |> maybe_add_param(:sort, socket.assigns.browse_product_sort_by)
          |> maybe_add_param(:platform, socket.assigns.platform_filter)

        push_patch(socket, to: product_sets_path(socket, query_params))
      else
        socket
      end

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
  def handle_event("show_edit_product_set_modal", %{"product-set-id" => session_id}, socket) do
    session_id = normalize_id(session_id)
    session = ProductSets.get_product_set!(socket.assigns.brand_id, session_id)
    changeset = ProductSet.changeset(session, %{})

    socket =
      socket
      |> assign(:editing_product_set, session)
      |> assign(:product_set_edit_form, to_form(changeset))

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_edit_product_set_modal", _params, socket) do
    # Preserve expanded session in URL when closing edit modal
    path =
      case socket.assigns.expanded_product_set_id do
        nil -> product_sets_path(socket)
        session_id -> product_sets_path(socket, %{s: session_id})
      end

    socket =
      socket
      |> assign(:editing_product_set, nil)
      |> assign(
        :product_set_edit_form,
        to_form(ProductSet.changeset(%ProductSet{brand_id: socket.assigns.brand_id}, %{}))
      )
      |> push_patch(to: path)

    {:noreply, socket}
  end

  @impl true
  def handle_event("validate_edit_product_set", %{"product_set" => params}, socket) do
    changeset =
      socket.assigns.editing_product_set
      |> ProductSet.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :product_set_edit_form, to_form(changeset))}
  end

  @impl true
  def handle_event("update_product_set", %{"product_set" => product_set_params}, socket) do
    # Generate slug from name
    slug = ProductSets.slugify(product_set_params["name"])
    product_set_params = Map.put(product_set_params, "slug", slug)

    # Handle image upload - consume uploaded entries and get the key
    # For external uploads, the metadata from presign function is the first arg
    # We store just the key, not a URL, since we need to generate presigned URLs for display
    image_key =
      consume_uploaded_entries(socket, :notes_image, fn meta, _entry ->
        {:ok, meta.key}
      end)
      |> List.first()

    product_set_params =
      if image_key do
        Map.put(product_set_params, "notes_image_url", image_key)
      else
        product_set_params
      end

    case ProductSets.update_product_set(socket.assigns.editing_product_set, product_set_params) do
      {:ok, _session} ->
        socket =
          socket
          |> reload_product_sets()
          |> assign(:editing_product_set, nil)
          |> assign(
            :product_set_edit_form,
            to_form(ProductSet.changeset(%ProductSet{brand_id: socket.assigns.brand_id}, %{}))
          )
          |> put_flash(:info, "Product set updated successfully")

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        socket =
          socket
          |> assign(:product_set_edit_form, to_form(changeset))
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
          |> reload_product_sets()
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
      brand_id = get_in(socket.assigns.product_set_form.params, ["brand_id"])
      brand_id = if brand_id && brand_id != "", do: normalize_id(brand_id), else: nil

      socket =
        socket
        |> assign(:product_search_query, query)
        |> display_products_by_id(query, brand_id,
          selected_ids: :selected_product_ids,
          stream: :new_product_set_products,
          products_map: :new_product_set_products_map,
          total_count: :product_total_count,
          enter_hint: :show_product_enter_hint,
          display_order: :new_session_display_order
        )

      {:noreply, socket}
    else
      # Normal text search mode - hide the enter hint
      socket =
        socket
        |> assign(:product_search_query, query)
        |> assign(:product_page, 1)
        |> assign(:loading_products, true)
        |> assign(:show_product_enter_hint, false)
        |> load_products_for_new_session()

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("search_products_submit", %{"value" => query}, socket) do
    # Detect if input looks like product IDs (contains commas or is numeric-like)
    if looks_like_product_ids?(query) do
      # ID-based lookup mode - select all displayed products
      socket =
        select_all_displayed_products(socket,
          selected_ids: :selected_product_ids,
          selected_order: :selected_product_order,
          stream: :new_product_set_products,
          products_map: :new_product_set_products_map,
          display_order: :new_session_display_order,
          enter_hint: :show_product_enter_hint
        )

      {:noreply, socket}
    else
      # Normal text search mode - auto-select if single result
      socket =
        maybe_auto_select_single_product(
          socket,
          :new_product_set_products_map,
          :selected_product_ids,
          :new_product_set_products
        )

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
    selected_order = socket.assigns.selected_product_order

    is_selecting = not MapSet.member?(selected_ids, product_id)

    new_selected_ids =
      if is_selecting do
        MapSet.put(selected_ids, product_id)
      else
        MapSet.delete(selected_ids, product_id)
      end

    # Maintain order: append when selecting, remove when deselecting
    new_selected_order =
      if is_selecting do
        selected_order ++ [product_id]
      else
        List.delete(selected_order, product_id)
      end

    # Find the product in the map and update it with the new selected state
    product = find_product_in_stream(socket.assigns.new_product_set_products_map, product_id)

    socket =
      socket
      |> assign(:selected_product_ids, new_selected_ids)
      |> assign(:selected_product_order, new_selected_order)

    # Update the product in the stream with the new selected state
    socket =
      if product do
        updated_product =
          Map.put(product, :selected, MapSet.member?(new_selected_ids, product_id))

        stream_insert(socket, :new_product_set_products, updated_product)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event(
        "generate_product_set_talking_points",
        %{"product-set-id" => session_id},
        socket
      ) do
    session_id = normalize_id(session_id)
    brand_id = socket.assigns.brand_id

    case AI.generate_product_set_talking_points_async(brand_id, session_id) do
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
    brand_id = socket.assigns.brand_id

    case AI.generate_talking_points_async(brand_id, product_id) do
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

  @impl true
  def handle_event("show_share_modal", %{"product-set-id" => product_set_id}, socket) do
    product_set_id = normalize_id(product_set_id)
    token = ProductSets.generate_share_token(product_set_id)
    share_url = BrandRoutes.brand_url(socket.assigns.current_brand, "/share/#{token}")

    socket =
      socket
      |> assign(:share_product_set_id, product_set_id)
      |> assign(:share_url, share_url)

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_share_modal", _params, socket) do
    socket =
      socket
      |> assign(:share_product_set_id, nil)
      |> assign(:share_url, nil)
      |> assign(:share_url_copied, false)

    {:noreply, socket}
  end

  @impl true
  def handle_event("copy_share_url", _params, socket) do
    socket =
      socket
      |> push_event("copy", %{text: socket.assigns.share_url})
      |> assign(:share_url_copied, true)

    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_notes_image_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :notes_image, ref)}
  end

  @impl true
  def handle_event("remove_notes_image", _params, socket) do
    # Clear the notes_image_url from the editing session
    if socket.assigns.editing_product_set do
      case ProductSets.update_product_set(socket.assigns.editing_product_set, %{
             notes_image_url: nil
           }) do
        {:ok, updated_session} ->
          socket =
            socket
            |> reload_product_sets()
            |> assign(:editing_product_set, updated_session)
            |> assign(:product_set_edit_form, to_form(ProductSet.changeset(updated_session, %{})))
            |> put_flash(:info, "Product set image removed")

          {:noreply, socket}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to remove image")}
      end
    else
      {:noreply, socket}
    end
  end

  # =============================================================================
  # PAGE TAB NAVIGATION
  # =============================================================================

  @impl true
  def handle_event("change_page_tab", %{"tab" => tab}, socket) do
    params = build_tab_query_params(socket, page_tab: tab)
    {:noreply, push_patch(socket, to: product_sets_path(socket, params))}
  end

  # =============================================================================
  # PRODUCTS TAB EVENT HANDLERS (Browse all products)
  # =============================================================================

  @impl true
  def handle_event("browse_search_products", %{"value" => query}, socket) do
    socket = assign(socket, :browse_search_touched, true)

    query_params =
      %{pt: "products"}
      |> maybe_add_param(:q, query)
      |> maybe_add_param(:sort, socket.assigns.browse_product_sort_by)
      |> maybe_add_param(:platform, socket.assigns.platform_filter)

    {:noreply, push_patch(socket, to: product_sets_path(socket, query_params))}
  end

  @impl true
  def handle_event("browse_sort_changed", %{"sort" => sort_by}, socket) do
    query_params =
      %{pt: "products"}
      |> maybe_add_param(:q, socket.assigns.browse_product_search_query)
      |> maybe_add_param(:sort, sort_by)
      |> maybe_add_param(:platform, socket.assigns.platform_filter)

    {:noreply, push_patch(socket, to: product_sets_path(socket, query_params))}
  end

  @impl true
  def handle_event("browse_platform_filter_changed", %{"platform" => platform}, socket) do
    query_params =
      %{pt: "products"}
      |> maybe_add_param(:q, socket.assigns.browse_product_search_query)
      |> maybe_add_param(:sort, socket.assigns.browse_product_sort_by)
      |> maybe_add_param(:platform, platform)

    {:noreply, push_patch(socket, to: product_sets_path(socket, query_params))}
  end

  @impl true
  def handle_event("browse_load_more_products", _params, socket) do
    socket =
      socket
      |> assign(:loading_browse_products, true)
      |> load_products_for_browse(append: true)

    {:noreply, socket}
  end

  @impl true
  def handle_event("browse_show_edit_product_modal", %{"product-id" => product_id}, socket) do
    query_params =
      %{pt: "products", p: product_id}
      |> maybe_add_param(:q, socket.assigns.browse_product_search_query)
      |> maybe_add_param(:sort, socket.assigns.browse_product_sort_by)
      |> maybe_add_param(:platform, socket.assigns.platform_filter)

    {:noreply, push_patch(socket, to: product_sets_path(socket, query_params))}
  end

  @impl true
  def handle_event("browse_close_edit_product_modal", _params, socket) do
    query_params =
      %{pt: "products"}
      |> maybe_add_param(:q, socket.assigns.browse_product_search_query)
      |> maybe_add_param(:sort, socket.assigns.browse_product_sort_by)
      |> maybe_add_param(:platform, socket.assigns.platform_filter)

    socket =
      socket
      |> assign(:editing_product, nil)
      |> assign(:product_edit_form, to_form(Product.changeset(%Product{}, %{})))
      |> assign(:current_image_index, 0)
      |> push_patch(to: product_sets_path(socket, query_params))

    {:noreply, socket}
  end

  @impl true
  def handle_event("trigger_shopify_sync", _params, socket) do
    %{"brand_id" => socket.assigns.brand_id}
    |> ShopifySyncWorker.new()
    |> Oban.insert()

    socket =
      socket
      |> assign(:syncing, true)
      |> put_flash(:info, "Shopify sync initiated...")

    {:noreply, socket}
  end

  @impl true
  def handle_event("trigger_tiktok_sync", _params, socket) do
    %{"brand_id" => socket.assigns.brand_id}
    |> TiktokSyncWorker.new()
    |> Oban.insert()

    socket =
      socket
      |> assign(:tiktok_syncing, true)
      |> put_flash(:info, "TikTok sync initiated...")

    {:noreply, socket}
  end

  # Presign function for external S3 uploads
  defp presign_notes_image(entry, socket) do
    # Generate a unique key for the image
    # Use session ID if editing, otherwise use a temp identifier
    session_id =
      if socket.assigns.editing_product_set do
        socket.assigns.editing_product_set.id
      else
        "new-#{System.unique_integer([:positive])}"
      end

    # Generate unique filename with timestamp
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    extension = Path.extname(entry.client_name) |> String.downcase()
    key = "product-sets/#{session_id}/notes-image-#{timestamp}#{extension}"

    case Storage.presign_upload(key, entry.client_type) do
      {:ok, url} ->
        {:ok, %{uploader: "S3", key: key, url: url}, socket}

      {:error, reason} ->
        {:error, %{reason: reason}, socket}
    end
  end

  # Helper functions

  # Reloads just one session in the list without a full database reload
  defp reload_single_product_set(socket, session_id) do
    sessions = socket.assigns.product_sets

    # Find and reload just the affected session
    case Enum.find_index(sessions, &(&1.id == session_id)) do
      nil ->
        # Product set not in the current list, do nothing
        socket

      index ->
        # Reload only this session from the database
        updated_session = ProductSets.get_product_set!(socket.assigns.brand_id, session_id)

        # Replace the session in the list
        updated_sessions = List.replace_at(sessions, index, updated_session)

        assign(socket, :product_sets, updated_sessions)
    end
  end

  # Template helper for upload error messages
  def error_to_string(:too_large), do: "File is too large (max 5MB)"
  def error_to_string(:not_accepted), do: "Invalid file type"
  def error_to_string(:too_many_files), do: "Only one image allowed"
  def error_to_string(err), do: "Upload error: #{inspect(err)}"

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
    brand_id = socket.assigns.brand_id
    search_query = socket.assigns.product_search_query
    page = if append, do: socket.assigns.product_page + 1, else: 1

    try do
      result =
        Catalog.search_products_paginated(
          brand_id,
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
          socket.assigns.new_product_set_products_map
        else
          %{}
        end
        |> Map.merge(Map.new(products_with_state, &{&1.id, &1}))

      socket
      |> assign(:loading_products, false)
      |> assign(:new_product_set_products_map, products_map)
      |> stream(:new_product_set_products, products_with_state,
        reset: !append,
        at: if(append, do: -1, else: 0)
      )
      |> assign(:product_total_count, result.total)
      |> assign(:product_page, result.page)
      |> assign(:new_product_set_has_more, result.has_more)
    rescue
      _e ->
        socket
        |> assign(:loading_products, false)
        |> put_flash(:error, "Failed to load products")
    end
  end

  defp normalize_id(id) when is_integer(id), do: id
  defp normalize_id(id) when is_binary(id), do: String.to_integer(id)

  defp apply_url_params(socket, params) do
    socket
    |> apply_search_params(params)
    |> maybe_expand_product_set(params["s"])
    |> maybe_show_new_product_set_modal(params["new"])
  end

  defp apply_search_params(socket, params) do
    search_query = params["q"] || ""

    # Only reload if search query changed
    if socket.assigns.product_set_search_query != search_query do
      socket
      |> assign(:product_set_search_query, search_query)
      |> assign(:product_set_page, 1)
      |> assign(:loading_product_sets, true)
      |> load_product_sets()
    else
      socket
    end
  end

  defp maybe_expand_product_set(socket, nil), do: assign(socket, :expanded_product_set_id, nil)

  defp maybe_expand_product_set(socket, session_id_str) do
    session_id = normalize_id(session_id_str)
    # Verify session exists before expanding
    if Enum.any?(socket.assigns.product_sets, &(&1.id == session_id)) do
      socket
      |> assign(:expanded_product_set_id, session_id)
      |> push_event("scroll-to-product-set", %{product_set_id: session_id})
    else
      # Product set not found, ignore param
      assign(socket, :expanded_product_set_id, nil)
    end
  rescue
    ArgumentError ->
      # Invalid ID format, ignore param
      assign(socket, :expanded_product_set_id, nil)
  end

  defp maybe_show_new_product_set_modal(socket, nil), do: socket

  defp maybe_show_new_product_set_modal(socket, _value) do
    # "new" param exists (any value), show the new session modal and initialize state
    brand_id = socket.assigns.brand_id

    # Initialize session form with brand_id pre-set
    product_set_form =
      to_form(ProductSet.changeset(%ProductSet{brand_id: brand_id}, %{}))

    socket
    |> assign(:show_new_product_set_modal, true)
    |> assign(:product_set_form, product_set_form)
    |> assign(:product_search_query, "")
    |> assign(:product_page, 1)
    |> assign(:selected_product_ids, MapSet.new())
    |> assign(:selected_product_order, [])
    |> assign(:new_session_display_order, [])
    |> stream(:new_product_set_products, [], reset: true)
    |> assign(:new_product_set_has_more, false)
    |> load_products_for_new_session()
  end

  defp load_products_for_add_modal(socket, opts \\ [append: false]) do
    append = Keyword.get(opts, :append, false)

    session = socket.assigns.selected_product_set_for_product
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
            session.product_set_products
            |> Enum.map(& &1.product_id)

          result =
            Catalog.search_products_paginated(
              session.brand_id,
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

  defp add_products_to_product_set(session_id, product_ids) do
    # Get the next position for the first product
    next_position = ProductSets.get_next_position_for_product_set(session_id)

    # Add each product with incrementing positions
    results =
      product_ids
      |> Enum.with_index()
      |> Enum.map(fn {product_id, index} ->
        ProductSets.add_product_to_product_set(session_id, product_id, %{
          position: next_position + index
        })
      end)

    # Extract created PSP IDs from successful results
    created_psp_ids =
      results
      |> Enum.filter(fn result -> match?({:ok, _}, result) end)
      |> Enum.map(fn {:ok, psp} -> psp.id end)

    # Count successes and failures
    successes = length(created_psp_ids)
    failures = length(results) - successes

    cond do
      failures == 0 ->
        {:ok, created_psp_ids}

      successes > 0 ->
        # Some succeeded, some failed (likely duplicates)
        {:partial, successes, failures, created_psp_ids}

      true ->
        # All failed
        {:error, "Could not add products (they may already be in this product set)"}
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
  # Keys: selected_ids, stream, products_map, total_count, enter_hint, display_order
  defp display_products_by_id(socket, ids_input, brand_id, keys) do
    selected_ids_key = Keyword.fetch!(keys, :selected_ids)
    stream_key = Keyword.fetch!(keys, :stream)
    products_map_key = Keyword.fetch!(keys, :products_map)
    total_count_key = Keyword.fetch!(keys, :total_count)
    enter_hint_key = Keyword.fetch!(keys, :enter_hint)
    display_order_key = Keyword.fetch!(keys, :display_order)
    # Parse input: split by comma, newline, or whitespace
    product_ids =
      ids_input
      |> String.split(~r/[\s,]+/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if Enum.empty?(product_ids) do
      socket
      |> assign(enter_hint_key, false)
      |> assign(display_order_key, [])
    else
      {found_products, _not_found_ids} =
        Catalog.find_products_by_ids(brand_id, product_ids)

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

      # Track display order (preserves paste order from find_products_by_ids)
      display_order = Enum.map(found_products, & &1.id)

      # Show "Press Enter to select" hint if we found products
      show_hint = length(found_products) > 0

      # Reset stream with found products and update all related state
      socket
      |> assign(products_map_key, new_products_map)
      |> assign(display_order_key, display_order)
      |> assign(total_count_key, length(found_products))
      |> assign(enter_hint_key, show_hint)
      |> stream(stream_key, products_with_state, reset: true)
    end
  end

  # Select all products currently displayed in the grid (called on Enter)
  # Shows flash feedback about what was found/selected
  # Keys: selected_ids, selected_order, stream, products_map, display_order, enter_hint
  defp select_all_displayed_products(socket, keys) do
    selected_ids_key = Keyword.fetch!(keys, :selected_ids)
    selected_order_key = Keyword.fetch!(keys, :selected_order)
    stream_key = Keyword.fetch!(keys, :stream)
    products_map_key = Keyword.fetch!(keys, :products_map)
    display_order_key = Keyword.fetch!(keys, :display_order)
    enter_hint_key = Keyword.fetch!(keys, :enter_hint)

    products_map = socket.assigns[products_map_key]
    display_order = socket.assigns[display_order_key]

    if map_size(products_map) == 0 do
      socket
    else
      # Get all product IDs from the current display (use display_order to preserve paste order)
      displayed_product_ids = MapSet.new(display_order)

      # Merge into current selection
      current_selected = socket.assigns[selected_ids_key]
      new_selected = MapSet.union(current_selected, displayed_product_ids)

      # Merge into selection order, preserving paste order for new items
      current_order = socket.assigns[selected_order_key]

      new_order =
        current_order ++
          Enum.reject(display_order, fn id -> id in current_order end)

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
      newly_selected =
        MapSet.size(displayed_product_ids) -
          MapSet.size(MapSet.intersection(current_selected, displayed_product_ids))

      total_displayed = map_size(products_map)

      socket =
        socket
        |> assign(selected_ids_key, new_selected)
        |> assign(selected_order_key, new_order)
        |> assign(products_map_key, updated_products_map)
        |> assign(enter_hint_key, false)

      # Show feedback
      cond do
        newly_selected == 0 ->
          put_flash(socket, :info, "#{total_displayed} product(s) already selected")

        newly_selected == total_displayed && total_displayed == 1 ->
          put_flash(socket, :info, "Product selected")

        newly_selected == total_displayed ->
          put_flash(socket, :info, "#{total_displayed} product(s) selected")

        true ->
          put_flash(
            socket,
            :info,
            "#{newly_selected} new product(s) selected (#{total_displayed - newly_selected} already selected)"
          )
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
  defp load_product_sets(socket, opts \\ []) do
    append = Keyword.get(opts, :append, false)
    page = if append, do: socket.assigns.product_set_page + 1, else: 1
    search_query = socket.assigns.product_set_search_query

    result =
      ProductSets.list_product_sets_with_details_paginated(
        socket.assigns.brand_id,
        page: page,
        per_page: 20,
        search_query: search_query
      )

    # When appending, concatenate with existing sessions
    sessions =
      if append do
        socket.assigns.product_sets ++ result.product_sets
      else
        result.product_sets
      end

    socket
    |> assign(:loading_product_sets, false)
    |> assign(:product_sets, sessions)
    |> assign(:product_set_page, result.page)
    |> assign(:product_sets_has_more, result.has_more)
  end

  # Helper to reload sessions from page 1 (used after modifications)
  defp reload_product_sets(socket) do
    socket
    |> assign(:product_set_page, 1)
    |> load_product_sets()
  end

  # =============================================================================
  # PRODUCTS TAB HELPER FUNCTIONS
  # =============================================================================

  defp apply_page_tab(socket, params) do
    page_tab = params["pt"] || "sets"
    old_page_tab = socket.assigns.page_tab

    socket
    |> assign(:page_tab, page_tab)
    |> maybe_load_products_tab(page_tab, old_page_tab, params)
  end

  defp maybe_load_products_tab(socket, "products", old_page_tab, params) do
    # Apply browse product search params
    search_query = params["q"] || ""
    sort_by = params["sort"] || ""
    platform_filter = params["platform"] || ""
    product_id = params["p"]

    # Reload products if switching to products tab or params changed
    should_load =
      old_page_tab != "products" ||
        socket.assigns.browse_product_search_query != search_query ||
        socket.assigns.browse_product_sort_by != sort_by ||
        socket.assigns.platform_filter != platform_filter ||
        socket.assigns.browse_products_total_count == 0

    socket =
      socket
      |> assign(:browse_product_search_query, search_query)
      |> assign(:browse_product_sort_by, sort_by)
      |> assign(:platform_filter, platform_filter)

    socket =
      if should_load do
        socket
        |> assign(:browse_product_page, 1)
        |> assign(:loading_browse_products, true)
        |> load_products_for_browse()
      else
        socket
      end

    # Handle product modal from URL
    maybe_open_browse_product_modal(socket, product_id)
  end

  defp maybe_load_products_tab(socket, _tab, _old_tab, _params), do: socket

  defp maybe_open_browse_product_modal(socket, nil) do
    # No product in URL, close modal if it's open
    if socket.assigns.editing_product && socket.assigns.page_tab == "products" do
      socket
      |> assign(:editing_product, nil)
      |> assign(:product_edit_form, to_form(Product.changeset(%Product{}, %{})))
    else
      socket
    end
  end

  defp maybe_open_browse_product_modal(socket, product_id_str) do
    product_id = String.to_integer(product_id_str)
    product = Catalog.get_product_with_images!(socket.assigns.brand_id, product_id)

    changes = %{
      "original_price_cents" => format_cents_to_dollars(product.original_price_cents),
      "sale_price_cents" => format_cents_to_dollars(product.sale_price_cents)
    }

    changeset = Product.changeset(product, changes)

    socket
    |> assign(:editing_product, product)
    |> assign(:product_edit_form, to_form(changeset))
    |> assign(:current_image_index, 0)
  rescue
    Ecto.NoResultsError -> socket
    ArgumentError -> socket
  end

  defp load_products_for_browse(socket, opts \\ [append: false]) do
    append = Keyword.get(opts, :append, false)
    brand_id = socket.assigns.brand_id
    search_query = socket.assigns.browse_product_search_query
    sort_by = socket.assigns.browse_product_sort_by
    platform_filter = socket.assigns.platform_filter
    page = if append, do: socket.assigns.browse_product_page + 1, else: 1

    try do
      result =
        Catalog.search_products_paginated(
          brand_id,
          search_query: search_query,
          sort_by: sort_by,
          platform_filter: platform_filter,
          page: page,
          per_page: 20
        )

      # Add stream_index to each product for staggered animations
      products_with_index =
        result.products
        |> Enum.with_index(0)
        |> Enum.map(fn {product, index} ->
          Map.put(product, :stream_index, index)
        end)

      socket
      |> assign(:loading_browse_products, false)
      |> stream(:browse_products, products_with_index,
        reset: !append,
        at: if(append, do: -1, else: 0)
      )
      |> assign(:browse_products_total_count, result.total)
      |> assign(:browse_product_page, result.page)
      |> assign(:browse_products_has_more, result.has_more)
    rescue
      _e ->
        socket
        |> assign(:loading_browse_products, false)
        |> put_flash(:error, "Failed to load products")
    end
  end

  defp maybe_reload_browse_products(socket) do
    if socket.assigns.page_tab == "products" do
      socket
      |> assign(:browse_product_page, 1)
      |> assign(:loading_browse_products, true)
      |> load_products_for_browse()
    else
      socket
    end
  end

  # Check if a sync job is currently active (executing or available)
  defp sync_job_active?(worker_module, brand_id) do
    import Ecto.Query

    worker_name = inspect(worker_module)

    Pavoi.Repo.exists?(
      from(j in Oban.Job,
        where: j.worker == ^worker_name,
        where: j.state in ["executing", "available", "scheduled"],
        where: fragment("?->>'brand_id' = ?", j.args, ^to_string(brand_id))
      )
    )
  end

  defp product_sets_path(socket, params \\ "")

  defp product_sets_path(socket, params) when is_map(params) do
    build_product_sets_path(socket, query_suffix(params))
  end

  defp product_sets_path(socket, params) when is_binary(params) do
    build_product_sets_path(socket, params)
  end

  defp build_product_sets_path(socket, suffix) do
    BrandRoutes.brand_path(
      socket.assigns.current_brand,
      "/product-sets#{suffix}",
      socket.assigns.current_host
    )
  end

  defp query_suffix(params) do
    cleaned =
      params
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    if cleaned == %{} do
      ""
    else
      "?" <> URI.encode_query(cleaned)
    end
  end

  # Helper to build query params for tab navigation
  defp build_tab_query_params(socket, overrides) do
    base = %{pt: socket.assigns.page_tab}

    base =
      case socket.assigns.page_tab do
        "products" ->
          base
          |> maybe_add_param(:q, socket.assigns.browse_product_search_query)
          |> maybe_add_param(:sort, socket.assigns.browse_product_sort_by)
          |> maybe_add_param(:platform, socket.assigns.platform_filter)

        "sets" ->
          base
          |> maybe_add_param(:q, socket.assigns.product_set_search_query)
          |> maybe_add_param(:s, socket.assigns.expanded_product_set_id)

        _ ->
          base
      end

    Enum.reduce(overrides, base, fn {key, value}, acc ->
      case key do
        :page_tab -> Map.put(acc, :pt, value)
        _ -> Map.put(acc, key, value)
      end
    end)
    |> reject_default_tab_values()
  end

  defp reject_default_tab_values(params) do
    params
    |> Enum.reject(fn
      {_, ""} -> true
      {_, nil} -> true
      {:pt, "sets"} -> true
      _ -> false
    end)
    |> Map.new()
  end

  # Helper to build query params, only including non-empty values
  defp maybe_add_param(params, _key, ""), do: params
  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: Map.put(params, key, value)

  # =============================================================================
  # UNDO FUNCTIONALITY
  # =============================================================================

  # Push an undo action onto the stack for a product set
  defp push_undo_action(socket, product_set_id, action) do
    undo_history = socket.assigns.undo_history
    actions = Map.get(undo_history, product_set_id, [])
    new_actions = [action | actions]
    new_history = Map.put(undo_history, product_set_id, new_actions)
    assign(socket, :undo_history, new_history)
  end

  # Pop the most recent undo action for a product set
  defp pop_undo_action(socket, product_set_id) do
    undo_history = socket.assigns.undo_history

    case Map.get(undo_history, product_set_id, []) do
      [] ->
        {nil, socket}

      [action | rest] ->
        new_history = Map.put(undo_history, product_set_id, rest)
        {action, assign(socket, :undo_history, new_history)}
    end
  end

  # Execute an undo action and return result
  defp execute_undo_action(nil, _product_set_id), do: :noop

  defp execute_undo_action(
         %{type: :add_products, data: %{added_psp_ids: psp_ids}},
         _product_set_id
       ) do
    Enum.each(psp_ids, &ProductSets.remove_product_from_product_set_silent/1)
    {:ok, "Undid add #{length(psp_ids)} product(s)"}
  end

  defp execute_undo_action(%{type: :remove_product, data: psp_data}, _product_set_id) do
    case ProductSets.restore_product_to_product_set(psp_data) do
      {:ok, _psp} -> {:ok, "Restored removed product"}
      {:error, _reason} -> {:error, "Failed to restore product"}
    end
  end

  defp execute_undo_action(
         %{type: :reorder_products, data: %{previous_order: previous_order}},
         product_set_id
       ) do
    case ProductSets.reorder_products(product_set_id, previous_order) do
      {:ok, _count} -> {:ok, "Restored previous order"}
      {:error, _reason} -> {:error, "Failed to restore order"}
    end
  end

  defp execute_undo_action(_action, _product_set_id), do: {:error, "Unknown undo action"}

  # Template helper: Check if undo actions available for a product set
  def has_undo_actions?(undo_history, product_set_id) do
    case Map.get(undo_history, product_set_id, []) do
      [] -> false
      _ -> true
    end
  end

  # Template helper: Count of undo actions for tooltip
  def undo_action_count(undo_history, product_set_id) do
    undo_history
    |> Map.get(product_set_id, [])
    |> length()
  end
end
