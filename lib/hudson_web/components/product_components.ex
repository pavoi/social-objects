defmodule HudsonWeb.ProductComponents do
  @moduledoc """
  Reusable components for product management features.

  ## Stream + LiveComponent Pattern with Embedded Selection State

  This module implements a pattern for rendering product grids with streams AND
  dynamic state (like selection checkmarks). The solution embeds selection state
  in the stream data itself, enabling proper re-rendering via stream_insert.

  ### How It Works:

  1. **Selection state is part of stream data** - Each product in the stream includes
     a `:selected` boolean field that gets updated when selection changes.

  2. **Product loading includes selection state** - When loading products, we pre-compute
     the `:selected` field based on the current selection MapSet.

  3. **Event handlers use stream_insert** - When a product is selected/deselected:
     - Update the selection MapSet (for persistence/logic)
     - Use `stream_insert` to update that specific product in the stream with the new `:selected` value
     - The SelectCardComponent receives the updated product and re-renders

  4. **SelectCardComponent uses the `:selected` prop** - Simply reads `@product.selected`
     instead of checking against a MapSet, making it simple and reliable.

  ### Pattern in SessionsLive.Index:

  ```elixir
  # When loading products, include selection state
  products_with_state = Enum.map(products, fn product ->
    Map.put(product, :selected, MapSet.member?(socket.assigns.selected_product_ids, product.id))
  end)
  socket |> stream(:new_session_products, products_with_state, reset: true)

  # When toggling selection
  def handle_event("toggle_product_selection", %{"product-id" => product_id}, socket) do
    # Update the MapSet for persistence
    new_selected_ids = toggle_in_set(socket.assigns.selected_product_ids, product_id)

    # Update the stream item with new selection state
    product = find_product_in_stream(socket.assigns.streams.new_session_products, product_id)
    updated_product = Map.put(product, :selected, MapSet.member?(new_selected_ids, product_id))

    socket
    |> assign(:selected_product_ids, new_selected_ids)
    |> stream_insert(:new_session_products, updated_product)
  end
  ```

  ### SelectCardComponent in product_components.ex:

  ```elixir
  <div class={["product-card-select", @product.selected && "product-card-select--selected"]}>
    <div class={["product-card-select__checkmark", !@product.selected && "product-card-select__checkmark--hidden"]}>
      <!-- checkmark SVG -->
    </div>
  </div>
  ```

  The component simply reads `@product.selected` - no complex MapSet logic needed.
  """
  use Phoenix.Component

  import HudsonWeb.CoreComponents

  use Phoenix.VerifiedRoutes,
    endpoint: HudsonWeb.Endpoint,
    router: HudsonWeb.Router,
    statics: HudsonWeb.static_paths()

  alias Phoenix.LiveView.JS

  @doc """
  Renders the product edit modal dialog.

  This component handles editing product details including basic info, pricing,
  product details, and settings. It displays the product's primary image and
  provides form validation and submission.

  ## Required Assigns
  - `editing_product` - The product being edited (must have product_images preloaded)
  - `product_edit_form` - The form bound to the product changeset
  - `brands` - List of available brands for the dropdown

  ## Example

      <.product_edit_modal
        editing_product={@editing_product}
        product_edit_form={@product_edit_form}
        brands={@brands}
        current_image_index={@current_edit_image_index}
      />
  """
  attr :editing_product, :any, required: true, doc: "The product being edited"
  attr :product_edit_form, :any, required: true, doc: "The product form"
  attr :brands, :list, required: true, doc: "List of available brands"
  attr :current_image_index, :integer, default: 0, doc: "Current image index for carousel"

  def product_edit_modal(assigns) do
    ~H"""
    <%= if @editing_product do %>
      <.modal
        id="edit-product-modal"
        show={true}
        on_cancel={JS.push("close_edit_product_modal")}
        phx-hook="ProductEditModalKeyboard"
      >
        <div class="modal__header">
          <h2 class="modal__title">Edit Product</h2>
        </div>

        <div class="modal__body">
          <%= if @editing_product.product_images && length(@editing_product.product_images) > 0 do %>
            <div
              class="box box--bordered"
              style="max-width: 500px; margin-bottom: var(--space-md); padding-bottom: var(--space-md);"
            >
              <HudsonWeb.ImageComponents.image_carousel
                id_prefix={"edit-product-#{@editing_product.id}"}
                images={@editing_product.product_images}
                current_index={@current_image_index}
                mode={:full}
              />
            </div>
          <% end %>

          <.form
            for={@product_edit_form}
            phx-change="validate_product"
            phx-submit="save_product"
            class="stack stack--lg"
          >
            <div class="stack">
              <.input
                field={@product_edit_form[:brand_id]}
                type="select"
                label="Brand"
                options={Enum.map(@brands, fn b -> {b.name, b.id} end)}
                prompt="Select a brand"
              />

              <.input
                field={@product_edit_form[:name]}
                type="text"
                label="Product Name"
                placeholder="e.g., Tennis Bracelet"
              />

              <.input
                field={@product_edit_form[:description]}
                type="textarea"
                label="Description"
                placeholder="Detailed product description"
              />

              <.input
                field={@product_edit_form[:talking_points_md]}
                type="textarea"
                label="Talking Points"
                placeholder="- Point 1&#10;- Point 2&#10;- Point 3"
              />
            </div>

            <div class="stack">
              <.input
                field={@product_edit_form[:original_price_cents]}
                type="number"
                label="Original Price"
                placeholder="e.g., 19.95"
                step="0.01"
              />

              <.input
                field={@product_edit_form[:sale_price_cents]}
                type="number"
                label="Sale Price (optional)"
                placeholder="e.g., 14.95"
                step="0.01"
              />
            </div>

            <div class="stack">
              <.input
                field={@product_edit_form[:pid]}
                type="text"
                label="Product ID (PID)"
                placeholder="External product ID"
              />

              <.input
                field={@product_edit_form[:sku]}
                type="text"
                label="SKU"
                placeholder="Stock keeping unit"
              />
            </div>

            <div class="modal__footer">
              <.button
                type="button"
                phx-click={
                  JS.push("close_edit_product_modal")
                  |> HudsonWeb.CoreComponents.hide_modal("edit-product-modal")
                }
              >
                Cancel
              </.button>
              <.button type="submit" variant="primary" phx-disable-with="Saving...">
                Save Changes
              </.button>
            </div>
          </.form>
        </div>
      </.modal>
    <% end %>
    """
  end

  @doc """
  Renders a reusable product grid that can be used in different contexts.

  Supports two modes:
  - `:browse` - For browsing/editing products (/products page)
  - `:select` - For selecting products (New Session modal)

  ## Attributes
  - `products` - List of products to display (must have product_images preloaded)
  - `mode` - `:browse` or `:select` (default: :browse)
  - `search_query` - Current search query (for display)
  - `has_more` - Boolean indicating if more products are available
  - `on_product_click` - Event name to trigger when product is clicked
  - `on_search` - Event name to trigger on search (optional)
  - `on_load_more` - Event name to trigger on load more (optional)
  - `selected_ids` - MapSet of selected product IDs (for :select mode)
  - `show_prices` - Whether to show price info (default: false)
  - `show_search` - Whether to show search input (default: true)

  ## Example - Browse Mode (on /products page)

      <.product_grid
        products={@products}
        mode={:browse}
        search_query={@product_search_query}
        has_more={@products_has_more}
        on_product_click="show_edit_product_modal"
        on_search="search_products"
        on_load_more="load_more_products"
        show_prices={true}
        show_search={true}
      />

  ## Example - Select Mode (in New Session modal)

      <.product_grid
        products={@new_session_products}
        mode={:select}
        search_query={@product_search_query}
        has_more={@new_session_has_more}
        selected_ids={@selected_product_ids}
        on_product_click="toggle_product_selection"
        on_search="search_products"
        on_load_more="load_more_products"
        show_search={true}
      />
  """
  attr :products, :any, required: true, doc: "List of products to display"
  attr :mode, :atom, default: :browse, values: [:browse, :select], doc: "Grid mode"
  attr :search_query, :string, default: "", doc: "Current search query"
  attr :has_more, :boolean, default: false, doc: "Whether more products are available"
  attr :on_product_click, :string, required: true, doc: "Event to trigger on product click"
  attr :on_search, :string, default: nil, doc: "Event to trigger on search"
  attr :on_load_more, :string, default: nil, doc: "Event to trigger on load more"
  attr :selected_ids, :any, default: MapSet.new(), doc: "Selected product IDs (for select mode)"
  attr :show_prices, :boolean, default: false, doc: "Whether to show prices"
  attr :show_search, :boolean, default: true, doc: "Whether to show search input"
  attr :loading, :boolean, default: false, doc: "Whether products are currently loading"

  attr :search_placeholder, :string,
    default: "Search products...",
    doc: "Placeholder text for search input"

  attr :is_empty, :boolean, required: true, doc: "Whether the products collection is empty"

  attr :viewport_bottom, :any,
    default: nil,
    doc: "phx-viewport-bottom binding for infinite scroll"

  def product_grid(assigns) do
    ~H"""
    <div class={["product-grid", "product-grid--#{@mode}"]}>
      <%= if @show_search do %>
        <div class="product-grid__header">
          <div class="product-grid__search">
            <input
              type="text"
              placeholder={@search_placeholder}
              value={@search_query}
              phx-keyup={@on_search}
              phx-debounce="300"
              class="input input--sm"
            />
          </div>
          <%= if @mode == :select do %>
            <div class="product-grid__count">
              ({MapSet.size(@selected_ids)} selected)
            </div>
          <% end %>
        </div>
      <% end %>

      <div
        class="product-grid__grid"
        id="product-grid"
        phx-update="stream"
        phx-viewport-bottom={@viewport_bottom}
      >
        <%= if @is_empty do %>
          <div id="product-grid-empty" class="product-grid__empty">
            No products found. Try a different search.
          </div>
        <% else %>
          <%= for {dom_id, product} <- @products do %>
            <%= if @mode == :browse do %>
              <.live_component
                module={HudsonWeb.ProductComponents.BrowseCardComponent}
                id={dom_id}
                product={product}
                on_click={@on_product_click}
                show_prices={@show_prices}
              />
            <% else %>
              <.live_component
                module={HudsonWeb.ProductComponents.SelectCardComponent}
                id={dom_id}
                product={product}
                on_click={@on_product_click}
              />
            <% end %>
          <% end %>
        <% end %>
      </div>

      <%= if !@is_empty && @has_more do %>
        <div id="product-grid-loader" class="product-grid__loader">
          <%= if @loading do %>
            <div class="product-grid__loading-indicator">
              <div class="spinner"></div>
              <span>Loading more products...</span>
            </div>
          <% else %>
            <.button
              type="button"
              phx-click={@on_load_more}
              size="sm"
            >
              Load More Products
            </.button>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # LIVE COMPONENT: Product Selection Card
  # ============================================================================
  # This is a live_component that renders a selectable product card with a checkmark.
  # It's only used in :select mode for product grids with selection checkmarks.
  # The :selected state is embedded in the product data and updated via stream_insert.

  defmodule SelectCardComponent do
    use Phoenix.LiveComponent

    @moduledoc """
    A live component that renders a selectable product card with a checkbox indicator.

    Displays a product with its primary image and title, with visual feedback
    indicating selection state. Selection is toggled via the `on_click` callback.
    """

    @impl true
    def render(assigns) do
      ~H"""
      <div
        id={@id}
        class={["product-card-select", @product.selected && "product-card-select--selected"]}
        phx-click={@on_click}
        phx-value-product-id={@product.id}
        role="button"
        tabindex="0"
        aria-pressed={@product.selected}
        aria-label={"Select #{@product.name}"}
      >
        <div class={[
          "product-card-select__checkmark",
          !@product.selected && "product-card-select__checkmark--hidden"
        ]}>
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 20 20"
            fill="currentColor"
            class="w-5 h-5"
          >
            <path
              fill-rule="evenodd"
              d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z"
              clip-rule="evenodd"
            />
          </svg>
        </div>

        <%= if @product.primary_image do %>
          <img
            src={@product.primary_image.path}
            alt={@product.primary_image.alt_text}
            class="product-card-select__image"
            loading="lazy"
          />
        <% else %>
          <div class="product-card-select__image-placeholder">
            No Image
          </div>
        <% end %>

        <p class="product-card-select__name">{@product.name}</p>
      </div>
      """
    end
  end

  # ============================================================================
  # Browse Card Component (LiveComponent with Carousel)
  # ============================================================================

  defmodule BrowseCardComponent do
    @moduledoc """
    Stateful product card with image carousel for browse mode.

    Each card maintains its own image navigation state, allowing users to
    preview all product images by clicking dot indicators.
    """
    use HudsonWeb, :live_component

    alias HudsonWeb.ImageComponents

    @impl true
    def mount(socket) do
      {:ok, assign(socket, current_image_index: 0)}
    end

    @impl true
    def update(assigns, socket) do
      {:ok,
       socket
       |> assign(assigns)
       |> assign_new(:current_image_index, fn -> 0 end)}
    end

    @impl true
    def handle_event("goto_image", %{"index" => index}, socket) when is_integer(index) do
      max_index = length(socket.assigns.product.product_images) - 1
      safe_index = max(0, min(index, max_index))

      {:noreply, assign(socket, current_image_index: safe_index)}
    end

    @impl true
    def handle_event("goto_image", %{"index" => index_str}, socket) when is_binary(index_str) do
      index = String.to_integer(index_str)
      max_index = length(socket.assigns.product.product_images) - 1
      safe_index = max(0, min(index, max_index))

      {:noreply, assign(socket, current_image_index: safe_index)}
    end

    @impl true
    def handle_event("next_image", _params, socket) do
      max_index = length(socket.assigns.product.product_images) - 1
      new_index = min(socket.assigns.current_image_index + 1, max_index)

      {:noreply, assign(socket, current_image_index: new_index)}
    end

    @impl true
    def handle_event("previous_image", _params, socket) do
      new_index = max(socket.assigns.current_image_index - 1, 0)

      {:noreply, assign(socket, current_image_index: new_index)}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <div
        id={"browse-card-#{@product.id}"}
        class="product-card-browse"
        phx-click={@on_click}
        phx-value-product-id={@product.id}
        role="button"
        tabindex="0"
        aria-label={"Open #{@product.name}"}
      >
        <%= if @product.product_images && length(@product.product_images) > 0 do %>
          <ImageComponents.image_carousel
            id_prefix={"product-#{@product.id}"}
            images={@product.product_images}
            current_index={@current_image_index}
            mode={:compact}
            target={@myself}
          />
        <% else %>
          <div class="product-card-browse__image-placeholder">
            No Image
          </div>
        <% end %>

        <div class="product-card-browse__info">
          <p class="product-card-browse__name">{@product.name}</p>

          <%= if @show_prices do %>
            <div class="product-card-browse__pricing">
              <%= if @product.sale_price_cents do %>
                <span class="product-card-browse__price-original">
                  ${format_price_for_display(@product.original_price_cents)}
                </span>
                <span class="product-card-browse__price-sale">
                  ${format_price_for_display(@product.sale_price_cents)}
                </span>
              <% else %>
                <span class="product-card-browse__price">
                  <%= if @product.original_price_cents do %>
                    ${format_price_for_display(@product.original_price_cents)}
                  <% else %>
                    Price not set
                  <% end %>
                </span>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
      """
    end

    # Format price for product card display (dollar amount without $ symbol)
    defp format_price_for_display(cents) when is_integer(cents) do
      dollars = cents / 100
      :erlang.float_to_binary(dollars, decimals: 2)
    end

    defp format_price_for_display(_), do: "N/A"
  end
end
