defmodule HudsonWeb.ProductComponents do
  @moduledoc """
  Reusable components for product management features.
  """
  use Phoenix.Component

  import HudsonWeb.CoreComponents

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
      />
  """
  attr :editing_product, :any, required: true, doc: "The product being edited"
  attr :product_edit_form, :any, required: true, doc: "The product form"
  attr :brands, :list, required: true, doc: "List of available brands"

  def product_edit_modal(assigns) do
    ~H"""
    <%= if @editing_product do %>
      <.modal
        id="edit-product-modal"
        show={true}
        on_cancel={JS.push("close_edit_product_modal")}
      >
        <div class="modal__header">
          <h2 class="modal__title">Edit Product</h2>
        </div>

        <div class="modal__body">
          <%= if image = primary_image(@editing_product) do %>
            <div class="box box--bordered" style="max-width: 400px; margin-bottom: var(--space-md);">
              <img
                src={Hudson.Media.public_image_url(image.path)}
                alt={image.alt_text}
                style="width: 100%; height: auto; display: block; border-radius: var(--radius-sm);"
              />
              <p class="text-sm text-secondary" style="margin-top: var(--space-xs); text-align: center;">
                Product Image {if image.is_primary, do: "(Primary)"}
              </p>
            </div>
          <% end %>

          <.form
            for={@product_edit_form}
            phx-change="validate_product"
            phx-submit="save_product"
            class="stack stack--lg"
          >
            <div class="stack">
              <h3 class="text-lg font-semibold">Basic Information</h3>

              <.input
                field={@product_edit_form[:brand_id]}
                type="select"
                label="Brand"
                options={Enum.map(@brands, fn b -> {b.name, b.id} end)}
                prompt="Select a brand"
              />

              <.input
                field={@product_edit_form[:display_number]}
                type="number"
                label="Display Number"
                placeholder="e.g., 1"
              />

              <.input
                field={@product_edit_form[:name]}
                type="text"
                label="Product Name"
                placeholder="e.g., Tennis Bracelet"
              />

              <.input
                field={@product_edit_form[:short_name]}
                type="text"
                label="Short Name (Optional)"
                placeholder="Abbreviated name for displays"
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
                label="Talking Points (Markdown)"
                placeholder="- Point 1&#10;- Point 2&#10;- Point 3"
              />
            </div>

            <div class="stack">
              <h3 class="text-lg font-semibold">Pricing</h3>

              <.input
                field={@product_edit_form[:original_price_cents]}
                type="number"
                label="Original Price (cents)"
                placeholder="e.g., 1995 for $19.95"
                step="1"
              />

              <.input
                field={@product_edit_form[:sale_price_cents]}
                type="number"
                label="Sale Price (cents, optional)"
                placeholder="e.g., 1495 for $14.95"
                step="1"
              />
            </div>

            <div class="stack">
              <h3 class="text-lg font-semibold">Product Details</h3>

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

              <.input
                field={@product_edit_form[:stock]}
                type="number"
                label="Stock Quantity"
                placeholder="e.g., 100"
                min="0"
              />

              <.input
                field={@product_edit_form[:external_url]}
                type="text"
                label="External URL"
                placeholder="https://..."
              />
            </div>

            <div class="stack">
              <h3 class="text-lg font-semibold">Settings</h3>

              <.input
                field={@product_edit_form[:is_featured]}
                type="checkbox"
                label="Featured Product"
              />

              <.input
                field={@product_edit_form[:tags]}
                type="text"
                label="Tags (comma-separated)"
                placeholder="jewelry, gold, bracelet"
              />
            </div>

            <div class="modal__footer">
              <.button
                type="button"
                phx-click={JS.push("close_edit_product_modal") |> HudsonWeb.CoreComponents.hide_modal("edit-product-modal")}
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

  # Helper for getting primary image from product
  defp primary_image(product) do
    product.product_images
    |> Enum.find(& &1.is_primary)
    |> case do
      nil -> List.first(product.product_images)
      image -> image
    end
  end
end
