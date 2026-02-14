defmodule SocialObjectsWeb.ProductComponents do
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

  import SocialObjectsWeb.CoreComponents
  import SocialObjectsWeb.ViewHelpers, only: [format_number: 1]

  use Phoenix.VerifiedRoutes,
    endpoint: SocialObjectsWeb.Endpoint,
    router: SocialObjectsWeb.Router,
    statics: SocialObjectsWeb.static_paths()

  alias Phoenix.LiveView.JS

  @doc """
  Displays product variants in a clean, structured format.

  Shows variant title, price, and SKU (in non-compact mode).
  For products with many variants, shows first 5 with "Show more" button.

  ## Attributes
  - `variants` - List of ProductVariant structs (optional)
  - `compact` - Boolean for compact display mode (default: false)
  """
  attr :variants, :list, default: []
  attr :compact, :boolean, default: false

  def product_variants(assigns) do
    # Prepare variant data
    assigns =
      assigns
      |> assign(:initial_variants, Enum.take(assigns.variants, 5))
      |> assign(:remaining_variants, Enum.drop(assigns.variants, 5))
      |> assign(:has_more, length(assigns.variants) > 5)
      |> assign(:remaining_count, max(0, length(assigns.variants) - 5))
      |> assign(:variant_id, "variants-#{:erlang.phash2(assigns.variants)}")

    ~H"""
    <%= if @variants && length(@variants) > 0 do %>
      <div class={["product-variants", @compact && "product-variants--compact"]}>
        <%= if @compact do %>
          <%!-- Compact mode: grid of chips with 1-line limit --%>
          <div id={@variant_id} class="product-variants__compact-container" phx-hook="VariantOverflow">
            <div class="product-variants__header">
              <h3 class="product-variants__title">
                Variants ({length(@variants)})
              </h3>
              <button
                type="button"
                id={"#{@variant_id}-expand"}
                class="product-variants__expand"
                style="display: none;"
                phx-click={
                  JS.toggle_class("product-variants__grid-wrapper--expanded",
                    to: "##{@variant_id} .product-variants__grid-wrapper"
                  )
                  |> JS.toggle_class("product-variants__expand--expanded",
                    to: "##{@variant_id}-expand"
                  )
                }
              >
                <span class="product-variants__expand-icon"></span>
              </button>
            </div>
            <div class="product-variants__grid-wrapper">
              <div class="product-variants__grid">
                <%= for variant <- @variants do %>
                  <.variant_chip variant={variant} />
                <% end %>
              </div>
            </div>
          </div>
        <% else %>
          <h3 class="product-variants__title">
            Variants ({length(@variants)})
          </h3>
          <%!-- Full mode: grid of chips with expand/collapse for many variants --%>
          <div class="product-variants__grid-wrapper product-variants__grid-wrapper--expanded">
            <div class="product-variants__grid">
              <%= for variant <- @initial_variants do %>
                <.variant_chip variant={variant} />
              <% end %>

              <%= if @has_more do %>
                <div
                  id={"#{@variant_id}-more"}
                  class="product-variants__more product-variants__more--hidden"
                >
                  <%= for variant <- @remaining_variants do %>
                    <.variant_chip variant={variant} />
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>

          <%= if @has_more do %>
            <button
              type="button"
              id={"#{@variant_id}-toggle"}
              class="product-variants__toggle"
              phx-click={
                JS.toggle_class("product-variants__more--hidden",
                  to: "##{@variant_id}-more"
                )
                |> JS.toggle_class("product-variants__toggle--expanded",
                  to: "##{@variant_id}-toggle"
                )
              }
            >
              Show all {@remaining_count} more variants
            </button>
          <% end %>
        <% end %>
      </div>
    <% end %>
    """
  end

  # Shared variant chip component used by both compact and full modes
  attr :variant, :map, required: true

  defp variant_chip(assigns) do
    ~H"""
    <div class="product-variant-chip">
      <span class="product-variant-chip__title">{@variant.title}</span>
      <%= if @variant.compare_at_price_cents do %>
        <span class="product-variant-chip__price-sale">
          ${format_price_cents(@variant.price_cents)}
        </span>
        <span class="product-variant-chip__price-original">
          ${format_price_cents(@variant.compare_at_price_cents)}
        </span>
      <% else %>
        <span class="product-variant-chip__price">
          ${format_price_cents(@variant.price_cents)}
        </span>
      <% end %>
    </div>
    """
  end

  defp format_price_cents(nil), do: "N/A"

  defp format_price_cents(cents) when is_integer(cents) do
    dollars = cents / 100
    :erlang.float_to_binary(dollars, decimals: 2)
  end

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
  attr :generating, :boolean, default: false, doc: "Whether talking points are being generated"
  attr :public_view, :boolean, default: false, doc: "Whether this is a read-only public view"

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
          <h2 class="modal__title">{@editing_product.name}</h2>
        </div>

        <div class="modal__body product-modal">
          <%!-- Image Carousel --%>
          <%= if @editing_product.product_images && length(@editing_product.product_images) > 0 do %>
            <div class="product-modal__section">
              <div class="product-modal__carousel">
                <SocialObjectsWeb.ImageComponents.image_carousel
                  id_prefix={"edit-product-#{@editing_product.id}"}
                  images={@editing_product.product_images}
                  current_index={@current_image_index}
                  mode={:full}
                />
              </div>
            </div>
          <% end %>

          <%!-- TikTok Shop Performance (non-public only) --%>
          <%= if not @public_view and @editing_product.tiktok_product_id do %>
            <div class="product-modal__section product-modal__section--bordered">
              <h3 class="product-modal__section-title">TikTok Shop Performance</h3>

              <%= if @editing_product.performance_synced_at do %>
                <div class="product-performance__grid">
                  <div class="product-performance__stat">
                    <span class="product-performance__label">Total GMV</span>
                    <span class="product-performance__value">
                      ${format_price_cents(@editing_product.gmv_cents)}
                    </span>
                  </div>

                  <div class="product-performance__stat">
                    <span class="product-performance__label">Items Sold</span>
                    <span class="product-performance__value">
                      {format_number(@editing_product.items_sold)}
                    </span>
                  </div>

                  <div class="product-performance__stat">
                    <span class="product-performance__label">Orders</span>
                    <span class="product-performance__value">
                      {format_number(@editing_product.orders)}
                    </span>
                  </div>

                  <div class="product-performance__stat">
                    <span class="product-performance__label">Avg Order Value</span>
                    <span class="product-performance__value">
                      <%= if @editing_product.orders > 0 do %>
                        ${format_price_cents(div(@editing_product.gmv_cents, @editing_product.orders))}
                      <% else %>
                        --
                      <% end %>
                    </span>
                  </div>
                </div>

                <div class="product-performance__sync-time">
                  Last synced {format_relative_time(@editing_product.performance_synced_at)}
                </div>
              <% else %>
                <div class="product-performance__empty">
                  Performance data not yet synced.
                </div>
              <% end %>
            </div>
          <% end %>

          <%!-- Pricing & Product Info --%>
          <div class="product-modal__section product-modal__section--bordered">
            <div class="product-modal__info-row">
              <span class="product-modal__label">Original Price</span>
              <span class="product-modal__value">
                ${format_price_cents(@editing_product.original_price_cents)}
              </span>
            </div>

            <%= if @editing_product.sale_price_cents do %>
              <div class="product-modal__info-row">
                <span class="product-modal__label">Sale Price</span>
                <span class="product-modal__value product-modal__value--sale">
                  ${format_price_cents(@editing_product.sale_price_cents)}
                </span>
              </div>
            <% end %>

            <%= if @editing_product.pid do %>
              <div class="product-modal__info-row">
                <span class="product-modal__label">Shopify ID</span>
                <span class="product-modal__value product-modal__value--mono">
                  {SocialObjects.Shopify.GID.display_id(@editing_product.pid)}
                </span>
              </div>
            <% end %>

            <%= if @editing_product.tiktok_product_id do %>
              <div class="product-modal__info-row">
                <span class="product-modal__label">TikTok ID</span>
                <span class="product-modal__value product-modal__value--mono">
                  {@editing_product.tiktok_product_id}
                </span>
              </div>
            <% end %>

            <%= if @editing_product.sku do %>
              <div class="product-modal__info-row">
                <span class="product-modal__label">SKU</span>
                <span class="product-modal__value product-modal__value--mono">
                  {@editing_product.sku}
                </span>
              </div>
            <% end %>

            <%= if @editing_product.size_range do %>
              <div class="product-modal__info-row">
                <span class="product-modal__label">Sizes</span>
                <span class="product-modal__value">{@editing_product.size_range}</span>
              </div>
            <% end %>
          </div>

          <%!-- Description --%>
          <%= if @editing_product.description do %>
            <div class="product-modal__section product-modal__section--bordered">
              <h3 class="product-modal__section-title">Description</h3>
              <div class="product-modal__description">
                {Phoenix.HTML.raw(@editing_product.description)}
              </div>
            </div>
          <% end %>

          <%!-- Talking Points --%>
          <div class="product-modal__section product-modal__section--bordered">
            <div class="product-modal__section-header">
              <h3 class="product-modal__section-title">Talking Points</h3>
              <%= unless @public_view do %>
                <button
                  type="button"
                  class={["button button--sm button--ghost", @generating && "button--disabled"]}
                  phx-click="generate_product_talking_points"
                  phx-value-product-id={@editing_product.id}
                  disabled={@generating}
                >
                  <%= if @generating do %>
                    <svg
                      class="size-4 animate-spin"
                      viewBox="0 0 24 24"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="2"
                      stroke-linecap="round"
                      stroke-linejoin="round"
                    >
                      <path d="M21 12a9 9 0 0 0-9-9 9.75 9.75 0 0 0-6.74 2.74L3 8" /><path d="M3 3v5h5" /><path d="M3 12a9 9 0 0 0 9 9 9.75 9.75 0 0 0 6.74-2.74L21 16" /><path d="M16 21h5v-5" />
                    </svg>
                    Generating...
                  <% else %>
                    <svg
                      class="size-4"
                      viewBox="0 0 24 24"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="2"
                      stroke-linecap="round"
                      stroke-linejoin="round"
                    >
                      <path d="M12 2L9 9l-7 3 7 3 3 7 3-7 7-3-7-3-3-7z" />
                    </svg>
                    Generate
                  <% end %>
                </button>
              <% end %>
            </div>
            <%= if @public_view do %>
              <div class="product-modal__talking-points-readonly">
                {@editing_product.talking_points_md || "No talking points available."}
              </div>
            <% else %>
              <.form
                id="edit-product-form"
                for={@product_edit_form}
                phx-change="validate_product"
                phx-submit="save_product"
              >
                <.input
                  field={@product_edit_form[:talking_points_md]}
                  type="textarea"
                  placeholder="Key features and highlights for the livestream..."
                />
              </.form>
            <% end %>
          </div>

          <%!-- Product Variants --%>
          <%= if @editing_product.product_variants && length(@editing_product.product_variants) > 0 do %>
            <div class="product-modal__section product-modal__section--bordered">
              <.product_variants variants={@editing_product.product_variants} />
            </div>
          <% end %>
        </div>

        <div class="modal__footer">
          <%= if @public_view do %>
            <.button
              type="button"
              variant="primary"
              phx-click={
                JS.push("close_product_modal")
                |> SocialObjectsWeb.CoreComponents.hide_modal("edit-product-modal")
              }
            >
              Close
            </.button>
          <% else %>
            <.button
              type="button"
              variant="outline"
              phx-click={
                JS.push("close_edit_product_modal")
                |> SocialObjectsWeb.CoreComponents.hide_modal("edit-product-modal")
              }
            >
              Cancel
            </.button>
            <.button
              type="submit"
              form="edit-product-form"
              variant="primary"
              phx-disable-with="Saving..."
            >
              Save Changes
            </.button>
          <% end %>
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

  attr :search_touched, :boolean,
    default: false,
    doc: "Whether search has been used (disables animations)"

  attr :has_more, :boolean, default: false, doc: "Whether more products are available"
  attr :on_product_click, :string, required: true, doc: "Event to trigger on product click"
  attr :on_search, :string, default: nil, doc: "Event to trigger on search"

  attr :on_search_submit, :string,
    default: nil,
    doc: "Event to trigger on search submit (Enter key)"

  attr :on_load_more, :string, default: nil, doc: "Event to trigger on load more"
  attr :selected_ids, :any, default: MapSet.new(), doc: "Selected product IDs (for select mode)"
  attr :show_prices, :boolean, default: false, doc: "Whether to show prices"
  attr :show_search, :boolean, default: true, doc: "Whether to show search input"
  attr :loading, :boolean, default: false, doc: "Whether products are currently loading"

  attr :initial_load_done, :boolean,
    default: true,
    doc: "Whether initial load has completed (hides loading indicator on first load)"

  attr :search_placeholder, :string,
    default: "Search products...",
    doc: "Placeholder text for search input"

  attr :is_empty, :boolean, required: true, doc: "Whether the products collection is empty"

  attr :viewport_bottom, :any,
    default: nil,
    doc: "phx-viewport-bottom binding for infinite scroll"

  attr :use_dynamic_id, :boolean,
    default: false,
    doc: "Whether to use dynamic ID based on search query (for URL-based search)"

  attr :show_sort, :boolean, default: false, doc: "Whether to show sort dropdown"
  attr :sort_by, :string, default: "", doc: "Current sort option"
  attr :on_sort_change, :string, default: nil, doc: "Event to trigger on sort change"
  attr :platform_filter, :string, default: "", doc: "Current platform filter"

  attr :on_platform_filter_change, :string,
    default: nil,
    doc: "Event to trigger on platform filter change"

  attr :show_enter_hint, :boolean,
    default: false,
    doc: "Whether to show 'Press Enter to select' hint (for ID search mode)"

  def product_grid(assigns) do
    ~H"""
    <div class={[
      "product-grid",
      "product-grid--#{@mode}",
      @search_touched && "product-grid--searching"
    ]}>
      <%= if @show_search do %>
        <div class="product-grid__header">
          <div class="product-grid__controls">
            <div class="product-grid__search">
              <.search_input
                value={@search_query}
                on_change={@on_search}
                on_submit={@on_search_submit || @on_search}
                placeholder={@search_placeholder}
              />
            </div>
            <%= if @on_platform_filter_change do %>
              <div class="product-grid__filter">
                <form phx-change={@on_platform_filter_change}>
                  <select
                    id="platform-filter"
                    name="platform"
                    value={@platform_filter}
                    class="input input--sm"
                  >
                    <option value="">All Products</option>
                    <option value="shopify" selected={@platform_filter == "shopify"}>Shopify</option>
                    <option value="tiktok" selected={@platform_filter == "tiktok"}>
                      TikTok Shop
                    </option>
                  </select>
                </form>
              </div>
            <% end %>
            <%= if @show_sort do %>
              <div class="product-grid__sort">
                <form phx-change={@on_sort_change}>
                  <select
                    id="product-sort"
                    name="sort"
                    value={@sort_by}
                    class="input input--sm"
                  >
                    <option value="">-- Sort by --</option>
                    <option value="name" selected={@sort_by == "name"}>Name (A-Z)</option>
                    <option value="price_asc" selected={@sort_by == "price_asc"}>
                      Price: Low to High
                    </option>
                    <option value="price_desc" selected={@sort_by == "price_desc"}>
                      Price: High to Low
                    </option>
                  </select>
                </form>
              </div>
            <% end %>
          </div>
          <div class="product-grid__status">
            <%= if @show_enter_hint do %>
              <div class="product-grid__enter-hint">
                Press Enter to select
              </div>
            <% end %>
            <%= if @mode == :select do %>
              <div class="product-grid__count">
                ({MapSet.size(@selected_ids)} selected)
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <%= if @is_empty && @loading && @initial_load_done do %>
        <div class="product-grid__loader">
          <div class="product-grid__loading-indicator">
            <div class="spinner"></div>
            <span>Loading products...</span>
          </div>
        </div>
      <% end %>

      <%= if @is_empty && !@loading && @initial_load_done do %>
        <div class="product-grid__empty">
          No products found. Try a different search.
        </div>
      <% else %>
        <div
          class="product-grid__grid"
          id={
            if @use_dynamic_id do
              # Include search, sort, and platform filter in ID to force re-render on changes
              search_part =
                if @search_query == "", do: "all", else: String.replace(@search_query, " ", "-")

              sort_part = if @sort_by == "", do: "default", else: @sort_by
              platform_part = if @platform_filter == "", do: "all", else: @platform_filter
              "product-grid-#{search_part}-#{sort_part}-#{platform_part}"
            else
              "product-grid"
            end
          }
          phx-update="stream"
          phx-viewport-bottom={@viewport_bottom}
        >
          <%= for {dom_id, product} <- @products do %>
            <%= if @mode == :browse do %>
              <.live_component
                module={SocialObjectsWeb.ProductComponents.BrowseCardComponent}
                id={dom_id}
                product={product}
                on_click={@on_product_click}
                show_prices={@show_prices}
                index={product.stream_index}
              />
            <% else %>
              <.live_component
                module={SocialObjectsWeb.ProductComponents.SelectCardComponent}
                id={dom_id}
                product={product}
                on_click={@on_product_click}
              />
            <% end %>
          <% end %>
        </div>
      <% end %>

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
              variant="outline"
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
        data-product-tiktok-id={@product.tiktok_product_id}
        data-product-shopify-id={SocialObjectsWeb.ViewHelpers.extract_shopify_numeric_id(@product.pid)}
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
    use SocialObjectsWeb, :live_component

    alias SocialObjectsWeb.ImageComponents

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
      case Integer.parse(index_str) do
        {index, ""} when index >= 0 ->
          max_index = length(socket.assigns.product.product_images) - 1
          safe_index = max(0, min(index, max_index))
          {:noreply, assign(socket, current_image_index: safe_index)}

        _ ->
          {:noreply, socket}
      end
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
      # Calculate staggered animation delay: first item at 0.3s (production needs more time), increment 0.08s per item
      animation_delay =
        if Map.has_key?(assigns, :index) do
          "#{assigns.index * 0.08 + 0.3}s"
        else
          "0.3s"
        end

      # Position can be passed directly or via the product map
      position = Map.get(assigns, :position) || Map.get(assigns.product, :position)

      assigns =
        assigns
        |> assign(:animation_delay, animation_delay)
        |> assign(:position, position)

      ~H"""
      <div
        id={"browse-card-#{@product.id}"}
        class="product-card-browse"
        style={"animation-delay: #{@animation_delay};"}
        phx-click={@on_click}
        phx-value-product-id={@product.id}
        data-product-tiktok-id={@product.tiktok_product_id}
        data-product-shopify-id={SocialObjectsWeb.ViewHelpers.extract_shopify_numeric_id(@product.pid)}
        role="button"
        tabindex="0"
        aria-label={"Open #{@product.name}"}
      >
        <div class="product-card-browse__image-container">
          <%= if @position do %>
            <span class="product-card-browse__position">{@position}</span>
          <% end %>
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
        </div>

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

  # ============================================================================
  # Product Sets Page Tabs
  # ============================================================================

  @doc """
  Renders page-level tabs for the Product Sets page (Sets vs Products).

  ## Assigns
  - `active_tab` - The currently active tab ("sets" or "products")
  - `actions` slot - Optional right-aligned content

  ## Example
      <.product_sets_page_tabs active_tab={@page_tab}>
        <:actions>
          <.button>New Product Set</.button>
        </:actions>
      </.product_sets_page_tabs>
  """
  attr :active_tab, :string, required: true
  slot :actions, doc: "Right-aligned content to display inline with tabs"

  def product_sets_page_tabs(assigns) do
    ~H"""
    <div class="page-tabs">
      <div class="page-tabs__tabs">
        <button
          type="button"
          class={["page-tab", @active_tab == "sets" && "page-tab--active"]}
          phx-click="change_page_tab"
          phx-value-tab="sets"
        >
          Sets
        </button>
        <button
          type="button"
          class={["page-tab", @active_tab == "products" && "page-tab--active"]}
          phx-click="change_page_tab"
          phx-value-tab="products"
        >
          Products
        </button>
      </div>
      <%= if @actions != [] do %>
        <div class="page-tabs__actions">
          {render_slot(@actions)}
        </div>
      <% end %>
    </div>
    """
  end
end
