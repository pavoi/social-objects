defmodule HudsonWeb.ProductsLive.Index do
  use HudsonWeb, :live_view

  alias Hudson.{Catalog, Media}
  alias Hudson.Catalog.Product

  import HudsonWeb.ProductComponents

  @impl true
  def mount(_params, _session, socket) do
    products = Catalog.list_products_with_images()
    brands = Catalog.list_brands()

    socket =
      socket
      |> assign(:products, products)
      |> assign(:brands, brands)
      |> assign(:editing_product, nil)
      |> assign(:product_edit_form, to_form(Product.changeset(%Product{}, %{})))

    {:ok, socket}
  end

  @impl true
  def handle_event("show_edit_product_modal", %{"product-id" => product_id}, socket) do
    product = Catalog.get_product_with_images!(product_id)

    changeset = Product.changeset(product, %{})

    socket =
      socket
      |> assign(:editing_product, product)
      |> assign(:product_edit_form, to_form(changeset))

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_edit_product_modal", _params, socket) do
    socket =
      socket
      |> assign(:editing_product, nil)
      |> assign(:product_edit_form, to_form(Product.changeset(%Product{}, %{})))

    {:noreply, socket}
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
  def handle_event("save_product", %{"product" => product_params}, socket) do
    # Convert price fields from dollars to cents
    product_params = convert_prices_to_cents(product_params)

    case Catalog.update_product(socket.assigns.editing_product, product_params) do
      {:ok, _product} ->
        # Refresh the products list
        products = Catalog.list_products_with_images()

        socket =
          socket
          |> assign(:products, products)
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

  # Helper functions

  defp convert_prices_to_cents(params) do
    params
    |> convert_price_field("original_price_cents")
    |> convert_price_field("sale_price_cents")
  end

  defp convert_price_field(params, field) do
    case Map.get(params, field) do
      nil ->
        params

      "" ->
        Map.put(params, field, nil)

      value when is_binary(value) ->
        # If value contains decimal point, treat as dollars, otherwise as cents
        if String.contains?(value, ".") do
          case Float.parse(value) do
            {dollars, _} -> Map.put(params, field, round(dollars * 100))
            :error -> params
          end
        else
          params
        end

      value when is_integer(value) ->
        params

      _ ->
        params
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="products-index">
      <div class="header">
        <h1>Products</h1>
        <.link navigate="/products/upload" class="button">Upload Images</.link>
      </div>

      <div class="products-grid">
        <%= for product <- @products do %>
          <div
            class="product-card-link"
            phx-click="show_edit_product_modal"
            phx-value-product-id={product.id}
          >
            <div class="product-card">
              <div class="product-image">
                <%= if product.primary_image do %>
                  <img
                    src={Media.public_image_url(product.primary_image.path)}
                    alt={product.name}
                    loading="lazy"
                  />
                <% else %>
                  <div class="no-image">No Image</div>
                <% end %>
              </div>

              <div class="product-info">
                <div class="product-number">#{product.display_number}</div>
                <h3 class="product-name">{product.name}</h3>

                <div class="product-price">
                  <%= if product.sale_price_cents do %>
                    <span class="original-price">
                      ${Float.round(product.original_price_cents / 100, 2)}
                    </span>
                    <span class="sale-price">${Float.round(product.sale_price_cents / 100, 2)}</span>
                  <% else %>
                    <span class="price">${Float.round(product.original_price_cents / 100, 2)}</span>
                  <% end %>
                </div>

                <%= if product.sku do %>
                  <div class="product-sku">SKU: {product.sku}</div>
                <% end %>

                <div class="product-images-count">
                  {length(product.product_images)} image(s)
                </div>
              </div>
            </div>
          </div>
        <% end %>
      </div>

      <.product_edit_modal
        editing_product={@editing_product}
        product_edit_form={@product_edit_form}
        brands={@brands}
      />
    </div>

    <style>
      .products-index {
        padding: 2rem;
        max-width: 1400px;
        margin: 0 auto;
      }

      .header {
        display: flex;
        justify-content: space-between;
        align-items: center;
        margin-bottom: 2rem;
      }

      .header h1 {
        font-size: 2rem;
        font-weight: bold;
        margin: 0;
      }

      .button {
        padding: 0.75rem 1.5rem;
        background: #3b82f6;
        color: white;
        border-radius: 0.5rem;
        text-decoration: none;
        font-weight: 500;
        transition: background 0.2s;
      }

      .button:hover {
        background: #2563eb;
      }

      .products-grid {
        display: grid;
        grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
        gap: 1.5rem;
      }

      .product-card-link {
        text-decoration: none;
        color: inherit;
        display: block;
      }

      .product-card {
        border: 1px solid #e5e7eb;
        border-radius: 0.5rem;
        overflow: hidden;
        background: white;
        transition: box-shadow 0.2s;
        height: 100%;
      }

      .product-card-link:hover .product-card {
        box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1);
        cursor: pointer;
      }

      .product-image {
        aspect-ratio: 1;
        background: #f3f4f6;
        display: flex;
        align-items: center;
        justify-content: center;
        overflow: hidden;
      }

      .product-image img {
        width: 100%;
        height: 100%;
        object-fit: cover;
      }

      .no-image {
        color: #9ca3af;
        font-size: 0.875rem;
      }

      .product-info {
        padding: 1rem;
      }

      .product-number {
        font-size: 0.75rem;
        color: #6b7280;
        font-weight: 600;
        margin-bottom: 0.25rem;
      }

      .product-name {
        font-size: 1rem;
        font-weight: 600;
        margin: 0 0 0.5rem 0;
        line-height: 1.4;
      }

      .product-price {
        display: flex;
        gap: 0.5rem;
        align-items: center;
        margin-bottom: 0.5rem;
      }

      .price, .sale-price {
        font-size: 1.125rem;
        font-weight: 700;
        color: #059669;
      }

      .original-price {
        font-size: 0.875rem;
        color: #9ca3af;
        text-decoration: line-through;
      }

      .product-sku {
        font-size: 0.75rem;
        color: #6b7280;
        margin-bottom: 0.5rem;
      }

      .product-images-count {
        font-size: 0.75rem;
        color: #6b7280;
        padding-top: 0.5rem;
        border-top: 1px solid #f3f4f6;
      }
    </style>
    """
  end
end
