defmodule PavoiWeb.HostViewComponents do
  @moduledoc """
  Shared components for host view display across different contexts:
  - Actual host view (sessions/:id/host)
  - Producer fullscreen preview
  - Producer split-screen preview

  These components ensure consistency across all three presentations.
  """
  use Phoenix.Component

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

    <%= if @session.notes && String.trim(@session.notes) != "" do %>
      <.session_description session={@session} />
    <% end %>

    <%= if @show_header do %>
      <.session_header
        session={@session}
        current_position={@current_position}
        total_products={@total_products}
      />
    <% end %>

    <%= if @current_session_product && @current_product do %>
      <div class="session-main">
        <.product_image_display
          product_images={@product_images}
          current_image_index={@current_image_index}
          current_product={@current_product}
          id_prefix={@id_prefix}
        />

        <div class="product-details">
          <.product_header
            session_product={@current_session_product}
            product={@current_product}
          />

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
      <.loading_state />
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
  Session description box component.
  Displays the session notes in a rounded box with session name as header.
  """
  attr :session, :map, required: true

  def session_description(assigns) do
    ~H"""
    <div class="session-description">
      <h2 class="session-description-header">{@session.name}</h2>
      <div class="session-description-content">
        {@session.notes}
      </div>
    </div>
    """
  end

  @doc """
  Session header with title and product count.
  """
  attr :session, :map, required: true
  attr :current_position, :integer, default: nil
  attr :total_products, :integer, required: true

  def session_header(assigns) do
    ~H"""
    <header class="session-header">
      <div class="session-title">{@session.name}</div>
      <div class="session-info">
        <%= if @current_position do %>
          <div class="product-count">
            Product {@current_position} / {@total_products}
          </div>
        <% end %>
      </div>
    </header>
    """
  end

  @doc """
  Product image display with carousel indicator.
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
        <%= if current_image do %>
          <div class="image-wrapper">
            <img
              id={"#{@id_prefix}-img-#{@current_product.id}-#{@current_image_index}"}
              src={current_image.path}
              alt={current_image.alt_text || @current_product.name}
              class="product-image"
              loading="lazy"
            />
          </div>
          <div class="image-indicator">
            {@current_image_index + 1} / {length(@product_images)}
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

  def product_header(assigns) do
    ~H"""
    <div class="product-header">
      <h1 class="product-name">
        {get_effective_name(@session_product)}
      </h1>

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
      <div class="talking-points">
        {@talking_points_html}
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

  ## Helper functions (shared with LiveView modules)

  defp get_effective_name(session_product) do
    SessionProduct.effective_name(session_product)
  end

  defp get_effective_prices(session_product) do
    SessionProduct.effective_prices(session_product)
  end
end
