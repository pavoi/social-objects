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
  - `current_image_index` - Current image index (0-based)
  - `talking_points_html` - Rendered markdown HTML
  - `host_message` - Optional host message struct
  - `current_position` - Display position (1-based)
  - `total_products` - Total number of products
  - `show_header` - Whether to show session header (default: false)
  - `id_prefix` - Prefix for image IDs (default: "host")
  """
  attr :session, :map, required: true
  attr :current_session_product, :map, default: nil
  attr :current_product, :map, default: nil
  attr :product_images, :list, default: []
  attr :current_image_index, :integer, default: 0
  attr :talking_points_html, :any, default: nil
  attr :host_message, :map, default: nil
  attr :current_position, :integer, default: nil
  attr :total_products, :integer, required: true
  attr :show_header, :boolean, default: false
  attr :id_prefix, :string, default: "host"

  def host_content(assigns) do
    ~H"""
    <%!-- Session Header Bar (fixed at top, differentiated from product content) --%>
    <%= if @show_header do %>
      <.session_header_bar session={@session} total_products={@total_products} />
    <% end %>

    <%!-- Message Banner (when active) --%>
    <%= if @host_message do %>
      <.host_message_banner message={@host_message} />
    <% end %>

    <%= if @current_session_product && @current_product do %>
      <%!-- Product Header: Position block + Name + Price --%>
      <.product_header
        session_product={@current_session_product}
        product={@current_product}
        current_position={@current_position}
        total_products={@total_products}
      />

      <%!-- Main Content Area: Images | Text --%>
      <div class="host-content-area">
        <%!-- Images Column --%>
        <div class="host-images-column">
          <.product_image_display
            product_images={@product_images}
            current_image_index={@current_image_index}
            current_product={@current_product}
            id_prefix={@id_prefix}
          />
        </div>

        <%!-- Text Content Column --%>
        <div class="host-text-column">
          <%= if @current_product.description && String.trim(@current_product.description) != "" do %>
            <.product_description description={@current_product.description} />
          <% end %>

          <.talking_points_section talking_points_html={@talking_points_html} />
        </div>
      </div>

      <%!-- Variants (compact, at bottom) --%>
      <%= if @current_product.product_variants && length(@current_product.product_variants) > 0 do %>
        <div class="host-variants">
          <PavoiWeb.ProductComponents.product_variants
            variants={@current_product.product_variants}
            compact={true}
          />
        </div>
      <% end %>
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
  Session header bar - fixed compact bar at top with session info.
  Differentiated from product content with distinct background.
  """
  attr :session, :map, required: true
  attr :total_products, :integer, required: true

  def session_header_bar(assigns) do
    ~H"""
    <header class="host-session-header">
      <div class="host-session-header__left">
        <span class="host-session-header__title">{@session.name}</span>
        <span class="host-session-header__count">{@total_products} products</span>
      </div>
      <%= if @session.notes && String.trim(@session.notes) != "" do %>
        <div class="host-session-header__notes">{@session.notes}</div>
      <% end %>
    </header>
    """
  end

  @doc """
  Compact product image display with hero image and thumbnail strip.
  Designed to take less space while remaining functional.
  """
  attr :product_images, :list, required: true
  attr :current_image_index, :integer, required: true
  attr :current_product, :map, required: true
  attr :id_prefix, :string, required: true

  def product_image_display(assigns) do
    ~H"""
    <div class="host-images">
      <%= if @product_images && length(@product_images) > 0 do %>
        <% current_image = Enum.at(@product_images, @current_image_index) %>

        <%!-- Compact Hero Image --%>
        <%= if current_image do %>
          <div class="host-hero-wrapper">
            <img
              id={"#{@id_prefix}-hero-img"}
              src={current_image.path}
              alt={current_image.alt_text || @current_product.name}
              class="host-hero-image"
              loading="lazy"
            />
          </div>
        <% end %>

        <%!-- Thumbnail Strip (only show if more than 1 image) --%>
        <%= if length(@product_images) > 1 do %>
          <div class="host-thumbnails">
            <%= for {image, index} <- Enum.with_index(@product_images) do %>
              <button
                type="button"
                class={["host-thumbnail", @current_image_index == index && "host-thumbnail--active"]}
                phx-click="goto_image"
                phx-value-index={index}
              >
                <img
                  src={image.thumbnail_path || image.path}
                  alt={image.alt_text || "Image #{index + 1}"}
                  class="host-thumbnail__img"
                  loading="lazy"
                />
              </button>
            <% end %>
          </div>
        <% end %>
      <% else %>
        <div class="host-no-images">No images</div>
      <% end %>
    </div>
    """
  end

  @doc """
  Product header with position number block, name, and pricing.
  Redesigned for utilitarian display with prominent position badge.
  """
  attr :session_product, :map, required: true
  attr :product, :map, required: true
  attr :current_position, :integer, default: nil
  attr :total_products, :integer, default: nil

  def product_header(assigns) do
    ~H"""
    <div class="host-product-header">
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
    </div>
    """
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
end
