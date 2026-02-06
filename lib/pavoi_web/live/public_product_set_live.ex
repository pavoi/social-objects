defmodule PavoiWeb.PublicProductSetLive do
  @moduledoc """
  LiveView for publicly shared product sets.

  This is a read-only view that allows anyone with a valid share token
  to browse a product set and view product details. No authentication required.
  """
  use PavoiWeb, :live_view

  alias Pavoi.Catalog.Product
  alias Pavoi.ProductSets

  import PavoiWeb.ProductComponents
  import PavoiWeb.ViewHelpers

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      socket
      |> assign(:current_scope, nil)
      |> assign(:current_page, nil)

    case ProductSets.verify_share_token(token) do
      {:ok, product_set_id} ->
        try do
          product_set = ProductSets.get_product_set_for_public!(product_set_id)

          # Build stream data for the product grid
          products_with_state =
            product_set.product_set_products
            |> Enum.sort_by(& &1.position)
            |> Enum.with_index(0)
            |> Enum.map(fn {psp, index} ->
              psp.product
              |> add_primary_image()
              |> Map.put(:selected, false)
              |> Map.put(:stream_index, index)
              |> Map.put(:position, psp.position)
            end)

          {:ok,
           socket
           |> assign(:page_title, product_set.name)
           |> assign(:current_brand, product_set.brand)
           |> assign(:product_set, product_set)
           |> assign(:error, nil)
           |> assign(:editing_product, nil)
           |> assign(:current_image_index, 0)
           |> assign(:product_edit_form, to_form(Product.changeset(%Product{}, %{})))
           |> stream(:products, products_with_state)}
        rescue
          Ecto.NoResultsError ->
            {:ok,
             socket
             |> assign(:page_title, "Product Set Not Found")
             |> assign(:current_brand, nil)
             |> assign(:error, "This product set could not be found.")
             |> assign(:product_set, nil)}
        end

      {:error, :expired} ->
        {:ok,
         socket
         |> assign(:page_title, "Link Expired")
         |> assign(:current_brand, nil)
         |> assign(:error, "This share link has expired. Please request a new link.")
         |> assign(:product_set, nil)}

      {:error, _} ->
        {:ok,
         socket
         |> assign(:page_title, "Invalid Link")
         |> assign(:current_brand, nil)
         |> assign(:error, "This share link is invalid.")
         |> assign(:product_set, nil)}
    end
  end

  @impl true
  def handle_event("show_product", %{"product-id" => product_id}, socket) do
    product_id = String.to_integer(product_id)
    product_set = socket.assigns.product_set

    # Security: verify product belongs to this product set
    product_set_product =
      Enum.find(product_set.product_set_products, fn psp ->
        psp.product_id == product_id
      end)

    if product_set_product do
      product = product_set_product.product

      {:noreply,
       socket
       |> assign(:editing_product, product)
       |> assign(:current_image_index, 0)
       |> assign(:product_edit_form, to_form(Product.changeset(product, %{})))}
    else
      {:noreply, socket}
    end
  end

  # Handle both close button click and escape key from modal keyboard hook
  @impl true
  def handle_event(event, _params, socket)
      when event in ["close_product_modal", "close_edit_product_modal"] do
    {:noreply,
     socket
     |> assign(:editing_product, nil)
     |> assign(:current_image_index, 0)}
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
  def render(assigns) do
    if assigns.error do
      render_error(assigns)
    else
      render_product_set(assigns)
    end
  end

  defp render_error(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_brand={@current_brand}
      current_page={@current_page}
    >
      <div class="public-product-set public-product-set--error">
        <div class="public-product-set__error-container">
          <h1>Oops!</h1>
          <p>{@error}</p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp render_product_set(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_brand={@current_brand}
      current_page={@current_page}
    >
      <div class="public-product-set">
        <header class="public-product-set__header">
          <h1 class="public-product-set__title">{@product_set.name}</h1>
          <%= if @product_set.brand do %>
            <p class="public-product-set__brand">{@product_set.brand.name}</p>
          <% end %>
        </header>

        <main class="public-product-set__content">
          <.product_grid
            products={@streams.products}
            mode={:browse}
            search_query=""
            has_more={false}
            on_product_click="show_product"
            show_prices={true}
            show_search={false}
            loading={false}
            is_empty={Enum.empty?(@product_set.product_set_products)}
          />
        </main>

        <.product_edit_modal
          editing_product={@editing_product}
          product_edit_form={@product_edit_form}
          brands={[]}
          current_image_index={@current_image_index}
          generating={false}
          public_view={true}
        />
      </div>
    </Layouts.app>
    """
  end
end
