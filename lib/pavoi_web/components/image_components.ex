defmodule PavoiWeb.ImageComponents do
  @moduledoc """
  Image components for displaying product images.
  """

  use Phoenix.Component

  @doc """
  Renders an image carousel with dot indicators and keyboard navigation.

  Displays a single image at a time with dot indicators below. Users can:
  - Click dots to jump to a specific image
  - Use arrow keys for previous/next (when focused)
  - See visual indicator of current position

  ## Attributes

  - `id_prefix` (required) - Unique prefix for element IDs
  - `images` (required) - List of ProductImage structs
  - `current_index` (required) - Currently displayed image index (0-based)
  - `mode` (optional) - Display mode: :compact (cards) or :full (modal). Default: :compact
  - `target` (optional) - Phoenix LiveComponent target for scoped events
  - `class` (optional) - Additional CSS classes for container

  ## Examples

      <.image_carousel
        id_prefix="product-123"
        images={@product.product_images}
        current_index={@current_image_index}
        mode={:compact}
        target={@myself}
      />
  """
  attr :id_prefix, :string, required: true
  attr :images, :list, required: true
  attr :current_index, :integer, required: true
  attr :mode, :atom, default: :compact
  attr :target, :any, default: nil
  attr :class, :string, default: ""

  def image_carousel(assigns) do
    # Extract target CID if LiveComponent (store as string for data attribute)
    target_cid = if assigns[:target], do: to_string(assigns.target), else: nil
    assigns = assign(assigns, :target_cid, target_cid)

    ~H"""
    <div
      class={"image-carousel image-carousel--#{@mode} #{@class}"}
      phx-hook="ImageCarouselDrag"
      id={"#{@id_prefix}-carousel"}
      data-current-index={@current_index}
      data-total-images={length(@images)}
      data-mode={@mode}
      data-target={@target_cid}
    >
      <%= if @images && length(@images) > 0 do %>
        <%= if @mode == :full do %>
          <%!-- Full mode: Show all images with adjacent peek --%>
          <div class="image-carousel__image-wrapper">
            <%= for {image, index} <- Enum.with_index(@images) do %>
              <img
                id={"#{@id_prefix}-img-#{index}"}
                class="image-carousel__image"
                src={image.path}
                alt={image.alt_text || "Product image #{index + 1}"}
                loading="lazy"
              />
            <% end %>
          </div>
        <% else %>
          <%!-- Compact mode: Show all images with slide animation --%>
          <div class="image-carousel__image-wrapper">
            <%= for {image, index} <- Enum.with_index(@images) do %>
              <img
                id={"#{@id_prefix}-img-#{index}"}
                class="image-carousel__image"
                src={image.path}
                alt={image.alt_text || "Product image #{index + 1}"}
                loading="lazy"
              />
            <% end %>
          </div>
        <% end %>

        <%!-- Dot indicators (only show if multiple images) --%>
        <%= if length(@images) > 1 do %>
          <div class="image-carousel__dots">
            <%= for {_img, index} <- Enum.with_index(@images) do %>
              <button
                type="button"
                class={[
                  "image-carousel__dot",
                  @current_index == index && "image-carousel__dot--active"
                ]}
                phx-click="goto_image"
                phx-value-index={index}
                phx-target={@target}
                aria-label={"Go to image #{index + 1} of #{length(@images)}"}
                aria-current={if @current_index == index, do: "true", else: "false"}
              >
                <span class="image-carousel__dot-inner" />
              </button>
            <% end %>
          </div>

          <%!-- Hidden indicator for screen readers --%>
          <div class="sr-only" aria-live="polite" aria-atomic="true">
            Image {@current_index + 1} of {length(@images)}
          </div>
        <% end %>
      <% else %>
        <div class="image-carousel__empty">
          No images available
        </div>
      <% end %>
    </div>
    """
  end
end
