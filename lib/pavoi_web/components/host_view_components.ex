defmodule PavoiWeb.HostViewComponents do
  @moduledoc """
  Shared components for host view display across different contexts:
  - Actual host view (sessions/:id/host)
  - Controller fullscreen preview
  - Controller split-screen preview

  These components ensure consistency across all three presentations.
  """
  use Phoenix.Component

  import Phoenix.HTML, only: [raw: 1]
  import PavoiWeb.ViewHelpers

  alias Pavoi.Sessions
  alias Pavoi.Sessions.SessionProduct

  @doc """
  Main host content component that renders the complete host view.

  Note: This component renders the content WITHOUT an outer container.
  The parent template should provide the container with the appropriate
  class (.host-container, .host-preview, or .producer-fullscreen-host).

  ## Attributes
  - `session` - Session struct
  - `current_session_product` - Current SessionProduct
  - `current_product` - Current Product
  - `product_images` - List of ProductImage structs
  - `talking_points_html` - Rendered markdown HTML
  - `host_message` - Optional host message struct
  - `current_position` - Display position (1-based)
  - `total_products` - Total number of products
  - `show_header` - Whether to show session header (default: false)
  """
  attr :session, :map, required: true
  attr :current_session_product, :map, default: nil
  attr :current_product, :map, default: nil
  attr :product_images, :list, default: []
  attr :talking_points_html, :any, default: nil
  attr :host_message, :map, default: nil
  attr :current_position, :integer, default: nil
  attr :total_products, :integer, required: true
  attr :show_header, :boolean, default: false
  attr :products_panel_collapsed, :boolean, default: true
  attr :session_panel_collapsed, :boolean, default: true

  def host_content(assigns) do
    ~H"""
    <%!-- Message Banner (when active, above everything) --%>
    <%= if @host_message do %>
      <.host_message_banner message={@host_message} />
    <% end %>

    <%= if @current_session_product && @current_product do %>
      <%!-- SESSION PANEL: Collapsible header at top --%>
      <%= if @show_header do %>
        <.session_panel
          session={@session}
          total_products={@total_products}
          collapsed={@session_panel_collapsed}
        />
      <% end %>

      <%!-- PRODUCT HEADER: Full width above images --%>
      <.product_header
        session_product={@current_session_product}
        product={@current_product}
        current_position={@current_position}
        total_products={@total_products}
        variants={@current_product.product_variants || []}
      />

      <%!-- IMAGE PANEL: Full width --%>
      <div class="host-image-panel">
        <.product_image_display
          product_images={@product_images}
          current_product={@current_product}
        />
      </div>

      <%!-- PRODUCT SECTION: Description + Talking Points (full width) --%>
      <div class="host-product-section">
        <%!-- Description (compact) --%>
        <%= if @current_product.description && String.trim(@current_product.description) != "" do %>
          <.product_description description={@current_product.description} />
        <% end %>

        <%!-- Talking Points (primary content area) --%>
        <.talking_points_section talking_points_html={@talking_points_html} />
      </div>

      <%!-- Products Panel (bottom, collapsible) --%>
      <.products_panel
        session={@session}
        current_session_product={@current_session_product}
        collapsed={@products_panel_collapsed}
      />
    <% else %>
      <%= if @total_products == 0 do %>
        <.empty_session_state />
      <% else %>
        <.loading_state />
      <% end %>
    <% end %>
    """
  end

  @doc """
  Floating host message banner component.
  """
  attr :message, :map, required: true

  def host_message_banner(assigns) do
    ~H"""
    <div
      class={"host-message-banner host-message-banner--#{Map.get(@message, :color, Sessions.default_message_color())}"}
      id={"host-message-#{@message.id}"}
      key={@message.id}
    >
      <div class="host-message-content">
        {@message.text}
      </div>
    </div>
    """
  end

  @doc """
  Collapsible session panel - displays session title and notes in an expandable header.
  Similar to products_panel but at the top of the view.
  """
  attr :session, :map, required: true
  attr :total_products, :integer, required: true
  attr :collapsed, :boolean, default: true

  def session_panel(assigns) do
    # Split notes into paragraphs (on blank lines) for column layout
    notes_items =
      if assigns.session.notes && String.trim(assigns.session.notes) != "" do
        assigns.session.notes
        |> String.split(~r/\n\s*\n/, trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
      else
        []
      end

    assigns = assign(assigns, :notes_items, notes_items)

    ~H"""
    <div class={["host-session-panel", @collapsed && "host-session-panel--collapsed"]}>
      <div class="host-session-panel__header" phx-click="toggle_session_panel">
        <span class="host-session-panel__title">{@session.name}</span>
        <span class="host-session-panel__count">{@total_products} products</span>
        <svg
          class="host-session-panel__chevron"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
        >
          <polyline points="6 9 12 15 18 9"></polyline>
        </svg>
      </div>
      <div class="host-session-panel__body">
        <%= if length(@notes_items) > 0 do %>
          <div class="host-session-panel__notes-grid">
            <%= for item <- @notes_items do %>
              <div class="host-session-panel__note-card">{item}</div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Horizontal scrolling thumbnail carousel for product images.
  Compact display showing equal-sized thumbnails that scroll horizontally.
  """
  attr :product_images, :list, required: true
  attr :current_product, :map, required: true

  def product_image_display(assigns) do
    ~H"""
    <div class="host-images">
      <%= if @product_images && length(@product_images) > 0 do %>
        <div class="host-thumbnail-carousel">
          <%= for {image, index} <- Enum.with_index(@product_images) do %>
            <div class="host-carousel-thumb">
              <img
                src={image.thumbnail_path || image.path}
                alt={image.alt_text || "Image #{index + 1}"}
                class="host-carousel-thumb__img"
                loading="lazy"
              />
            </div>
          <% end %>
        </div>
      <% else %>
        <div class="host-no-images">No images</div>
      <% end %>
    </div>
    """
  end

  @doc """
  Product header with position number block, name, pricing, and variants.
  Redesigned for utilitarian display with prominent position badge.
  Variants are collapsible and default to collapsed.
  """
  attr :session_product, :map, required: true
  attr :product, :map, required: true
  attr :current_position, :integer, default: nil
  attr :total_products, :integer, default: nil
  attr :variants, :list, default: []

  def product_header(assigns) do
    assigns =
      assign(assigns, :variant_id, "header-variants-#{System.unique_integer([:positive])}")

    ~H"""
    <div class="host-product-header">
      <%!-- Main content: Position + Name + Price + Variants toggle --%>
      <div class="host-product-header__main">
        <%!-- Position Number Block --%>
        <%= if @current_position do %>
          <div class="host-product-position">
            {@current_position}
          </div>
        <% end %>

        <%!-- Product Name --%>
        <h1 class="host-product-name">
          {get_effective_name(@session_product)}
        </h1>

        <%!-- Pricing + Variants --%>
        <div class="host-product-pricing-row">
          <%!-- Pricing --%>
          <div class="host-product-pricing">
            <% prices = get_effective_prices(@session_product) %>
            <%= if prices.sale do %>
              <span class="host-product-price--sale">
                {format_price(prices.sale)}
              </span>
              <span class="host-product-price--original">
                {format_price(prices.original)}
              </span>
            <% else %>
              <span class="host-product-price">
                {format_price(prices.original)}
              </span>
            <% end %>
          </div>

          <%!-- Variants toggle button --%>
          <%= if @variants && length(@variants) > 0 do %>
            <button
              type="button"
              class="host-variants-toggle"
              phx-click={
                Phoenix.LiveView.JS.toggle_class("host-variants-row--expanded", to: "##{@variant_id}")
              }
            >
              <span class="host-variants-toggle__label">Variants ({length(@variants)})</span>
              <span class="host-variants-toggle__icon"></span>
            </button>
          <% end %>
        </div>
      </div>

      <%!-- Variants row (collapsed by default) --%>
      <%= if @variants && length(@variants) > 0 do %>
        <div id={@variant_id} class="host-variants-row">
          <div class="host-variants-grid">
            <%= for variant <- @variants do %>
              <div class="host-variant-chip">
                <span class="host-variant-chip__title">{variant.title || "Default"}</span>
                <%= if variant.compare_at_price_cents do %>
                  <span class="host-variant-chip__price-sale">
                    ${format_variant_price(variant.price_cents)}
                  </span>
                  <span class="host-variant-chip__price-original">
                    ${format_variant_price(variant.compare_at_price_cents)}
                  </span>
                <% else %>
                  <span class="host-variant-chip__price">
                    ${format_variant_price(variant.price_cents)}
                  </span>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp format_variant_price(nil), do: "N/A"

  defp format_variant_price(cents) when is_integer(cents) do
    dollars = cents / 100
    :erlang.float_to_binary(dollars, decimals: 2)
  end

  @doc """
  Product description section with subtle styling.
  Differentiated from talking points with background color.
  """
  attr :description, :string, required: true

  def product_description(assigns) do
    ~H"""
    <div class="host-description">
      <div class="host-description__label">Description</div>
      <div class="host-description__content">
        {raw(@description)}
      </div>
    </div>
    """
  end

  @doc """
  Talking points section with rendered markdown.
  Primary text content area with bullet styling emphasis.
  """
  attr :talking_points_html, :any, required: true

  def talking_points_section(assigns) do
    ~H"""
    <%= if @talking_points_html do %>
      <div class="host-talking-points">
        <div class="host-talking-points__label">Talking Points</div>
        <div class="host-talking-points__content">
          {@talking_points_html}
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  Collapsible products panel with horizontal scrolling product cards.
  Displays at the bottom of the host view for quick product navigation.
  """
  attr :session, :map, required: true
  attr :current_session_product, :map, default: nil
  attr :collapsed, :boolean, default: true

  def products_panel(assigns) do
    ~H"""
    <div class={["host-products-panel", @collapsed && "host-products-panel--collapsed"]}>
      <div class="host-products-panel__header" phx-click="toggle_products_panel">
        <span class="host-products-panel__title">All Products</span>
        <svg
          class="host-products-panel__chevron"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
        >
          <polyline points="6 9 12 15 18 9"></polyline>
        </svg>
      </div>

      <div class="host-products-panel__body">
        <div
          class="host-products-panel__scroll"
          id="host-products-scroll"
          phx-hook="HostProductsScroll"
          data-current-position={@current_session_product && @current_session_product.position}
        >
          <%= for sp <- Enum.sort_by(@session.session_products, & &1.position) do %>
            <button
              type="button"
              class={[
                "host-product-card",
                @current_session_product && @current_session_product.id == sp.id &&
                  "host-product-card--active"
              ]}
              phx-click="select_product_from_panel"
              phx-value-position={sp.position}
            >
              <div class="host-product-card__image-container">
                <span class="host-product-card__position">{sp.position}</span>
                <%= if image = primary_image(sp.product) do %>
                  <img
                    src={public_image_url(image.thumbnail_path || image.path)}
                    alt=""
                    class="host-product-card__image"
                    loading="lazy"
                  />
                <% end %>
              </div>
              <span class="host-product-card__name">{sp.featured_name || sp.product.name}</span>
            </button>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Loading state component.
  """
  def loading_state(assigns) do
    ~H"""
    <div class="host-state-container">
      <div class="host-loading">
        <div class="host-loading__spinner"></div>
        <p>Loading session...</p>
      </div>
    </div>
    """
  end

  @doc """
  Empty session state component shown when no products are in the session.
  """
  def empty_session_state(assigns) do
    ~H"""
    <div class="host-state-container">
      <div class="host-empty">
        <p class="host-empty__title">No products in this session</p>
        <p class="host-empty__subtitle">Add products to get started</p>
      </div>
    </div>
    """
  end

  ## Helper functions (shared with LiveView modules)

  defp get_effective_name(session_product) do
    SessionProduct.effective_name(session_product)
  end

  defp get_effective_prices(session_product) do
    SessionProduct.effective_prices(session_product)
  end

  defp primary_image(product) do
    product.product_images
    |> Enum.find(& &1.is_primary)
    |> case do
      nil -> List.first(product.product_images)
      image -> image
    end
  end
end
