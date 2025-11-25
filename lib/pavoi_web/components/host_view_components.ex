defmodule PavoiWeb.HostViewComponents do
  @moduledoc """
  Shared components for host view display across different contexts:
  - Actual host view (sessions/:id/host)
  - Producer fullscreen preview
  - Producer split-screen preview

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
  class (.session-container, .host-preview, or .producer-fullscreen-host).

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
    <%= if @host_message do %>
      <.host_message_banner message={@host_message} />
    <% end %>

    <%= if @current_session_product && @current_product do %>
      <div class="session-main">
        <div class="session-left-column">
          <%= if @show_header do %>
            <.session_header
              session={@session}
              current_position={@current_position}
              total_products={@total_products}
            />
          <% end %>
          <.product_image_display
            product_images={@product_images}
            current_image_index={@current_image_index}
            current_product={@current_product}
            id_prefix={@id_prefix}
          />
        </div>

        <div class="product-details">
          <.product_header
            session_product={@current_session_product}
            product={@current_product}
            current_position={@current_position}
            total_products={@total_products}
          />

          <%= if @current_product.description && String.trim(@current_product.description) != "" do %>
            <div class="product-description">{raw(@current_product.description)}</div>
          <% end %>

          <.talking_points_section talking_points_html={@talking_points_html} />

          <%= if @current_product.product_variants && length(@current_product.product_variants) > 0 do %>
            <PavoiWeb.ProductComponents.product_variants
              variants={@current_product.product_variants}
              compact={true}
            />
          <% end %>
        </div>
      </div>
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
  Unified session header with title, product count, and optional notes.
  """
  attr :session, :map, required: true
  attr :current_position, :integer, default: nil
  attr :total_products, :integer, required: true

  def session_header(assigns) do
    ~H"""
    <header class="session-header">
      <span class="session-title">{@session.name}</span>
      <%= if @session.notes && String.trim(@session.notes) != "" do %>
        <div class="session-notes">{@session.notes}</div>
      <% end %>
    </header>
    """
  end

  @doc """
  Product image display with hero image and thumbnail gallery.

  Shows a large hero image at the top with a scrollable grid of thumbnails below.
  Clicking a thumbnail or using arrow keys changes the hero image.
  """
  attr :product_images, :list, required: true
  attr :current_image_index, :integer, required: true
  attr :current_product, :map, required: true
  attr :id_prefix, :string, required: true

  def product_image_display(assigns) do
    ~H"""
    <div class="product-image-container">
      <%= if @product_images && length(@product_images) > 0 do %>
        <% current_image = Enum.at(@product_images, @current_image_index) %>

        <%!-- Hero Image (Key Image) --%>
        <%= if current_image do %>
          <div class="hero-image-wrapper">
            <img
              id={"#{@id_prefix}-hero-img"}
              src={current_image.path}
              alt={current_image.alt_text || @current_product.name}
              class="hero-image"
              loading="lazy"
            />
          </div>
        <% end %>

        <%!-- Thumbnail Gallery (only show if more than 1 image) --%>
        <%= if length(@product_images) > 1 do %>
          <div class="thumbnail-gallery">
            <%= for {image, index} <- Enum.with_index(@product_images) do %>
              <button
                type="button"
                class={["thumbnail-item", @current_image_index == index && "thumbnail-item--active"]}
                phx-click="goto_image"
                phx-value-index={index}
              >
                <img
                  src={image.thumbnail_path || image.path}
                  alt={image.alt_text || "Image #{index + 1}"}
                  class="thumbnail-image"
                  loading="lazy"
                />
              </button>
            <% end %>
          </div>
        <% end %>
      <% else %>
        <div class="no-images">No images available</div>
      <% end %>
    </div>
    """
  end

  @doc """
  Product header with name, pricing, and metadata.
  """
  attr :session_product, :map, required: true
  attr :product, :map, required: true
  attr :current_position, :integer, default: nil
  attr :total_products, :integer, default: nil

  def product_header(assigns) do
    ~H"""
    <div class="product-header">
      <div class="product-name-row">
        <h1 class="product-name">
          {get_effective_name(@session_product)}
        </h1>
        <%= if @current_position && @total_products do %>
          <span class="product-count">{@current_position} / {@total_products}</span>
        <% end %>
      </div>

      <div class="product-pricing">
        <% prices = get_effective_prices(@session_product) %>
        <%= if prices.sale do %>
          <span class="sale-price">
            {format_price(prices.sale)}
          </span>
          <span class="original-price">
            {format_price(prices.original)}
          </span>
        <% else %>
          <span class="price">
            {format_price(prices.original)}
          </span>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Talking points section with rendered markdown.
  """
  attr :talking_points_html, :any, required: true

  def talking_points_section(assigns) do
    ~H"""
    <%= if @talking_points_html do %>
      <div class="talking-points-wrapper">
        <div class="talking-points">
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
    <div class="session-main">
      <div class="loading-state">
        <div class="loading-spinner"></div>
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
    <div class="session-main">
      <div class="empty-state">
        <p class="empty-state-title">No products in this session</p>
        <p class="empty-state-subtitle">Add products to get started</p>
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
