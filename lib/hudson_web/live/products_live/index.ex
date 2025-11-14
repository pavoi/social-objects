defmodule HudsonWeb.ProductsLive.Index do
  use HudsonWeb, :live_view

  on_mount {HudsonWeb.NavHooks, :set_current_page}

  alias Hudson.Catalog
  alias Hudson.Catalog.Product

  import HudsonWeb.ProductComponents
  import HudsonWeb.ViewHelpers

  @impl true
  def mount(_params, _session, socket) do
    brands = Catalog.list_brands()

    socket =
      socket
      |> assign(:brands, brands)
      |> assign(:editing_product, nil)
      |> assign(:product_edit_form, to_form(Product.changeset(%Product{}, %{})))
      |> assign(:current_edit_image_index, 0)
      |> assign(:product_search_query, "")
      |> assign(:product_page, 1)
      |> assign(:product_total_count, 0)
      |> assign(:products_has_more, false)
      |> assign(:loading_products, false)
      |> stream(:products, [], limit: 60)
      |> load_products_for_browse()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> apply_url_params(params)

    {:noreply, socket}
  end

  @impl true
  def handle_event("show_edit_product_modal", %{"product-id" => product_id}, socket) do
    # Update URL to include product ID
    {:noreply, push_patch(socket, to: ~p"/products?#{%{p: product_id}}")}
  end

  @impl true
  def handle_event("close_edit_product_modal", _params, socket) do
    socket =
      socket
      |> assign(:editing_product, nil)
      |> assign(:product_edit_form, to_form(Product.changeset(%Product{}, %{})))
      |> assign(:current_edit_image_index, 0)
      |> push_patch(to: ~p"/products")

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
        socket =
          socket
          |> assign(:product_page, 1)
          |> assign(:loading_products, true)
          |> load_products_for_browse()
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

  @impl true
  def handle_event("search_products", %{"value" => query}, socket) do
    socket =
      socket
      |> assign(:product_search_query, query)
      |> assign(:product_page, 1)
      |> assign(:loading_products, true)
      |> load_products_for_browse()

    {:noreply, socket}
  end

  @impl true
  def handle_event("load_more_products", _params, socket) do
    socket =
      socket
      |> assign(:loading_products, true)
      |> load_products_for_browse(append: true)

    {:noreply, socket}
  end

  # Carousel navigation handlers for product edit modal
  @impl true
  def handle_event("goto_image", %{"index" => index_value}, socket) do
    # Only handle if editing a product (modal context)
    if socket.assigns.editing_product do
      # Handle both string and integer index values
      index = if is_binary(index_value), do: String.to_integer(index_value), else: index_value
      max_index = length(socket.assigns.editing_product.product_images) - 1
      safe_index = max(0, min(index, max_index))

      {:noreply, assign(socket, current_edit_image_index: safe_index)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("next_image", _params, socket) do
    # Only handle if editing a product (modal context)
    if socket.assigns.editing_product do
      max_index = length(socket.assigns.editing_product.product_images) - 1
      new_index = min(socket.assigns.current_edit_image_index + 1, max_index)

      {:noreply, assign(socket, current_edit_image_index: new_index)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("previous_image", _params, socket) do
    # Only handle if editing a product (modal context)
    if socket.assigns.editing_product do
      new_index = max(socket.assigns.current_edit_image_index - 1, 0)

      {:noreply, assign(socket, current_edit_image_index: new_index)}
    else
      {:noreply, socket}
    end
  end

  # Helper functions

  defp load_products_for_browse(socket, opts \\ [append: false]) do
    append = Keyword.get(opts, :append, false)
    search_query = socket.assigns.product_search_query
    page = if append, do: socket.assigns.product_page + 1, else: 1

    try do
      result =
        Catalog.search_products_paginated(
          search_query: search_query,
          page: page,
          per_page: 20
        )

      # Precompute primary images for all products
      products_with_images = Enum.map(result.products, &add_primary_image/1)

      socket
      |> assign(:loading_products, false)
      |> stream(:products, products_with_images,
        reset: !append,
        limit: 60,
        at: if(append, do: -1, else: 0)
      )
      |> assign(:product_total_count, result.total)
      |> assign(:product_page, result.page)
      |> assign(:products_has_more, result.has_more)
    rescue
      _e ->
        socket
        |> assign(:loading_products, false)
        |> put_flash(:error, "Failed to load products")
    end
  end

  defp apply_url_params(socket, params) do
    # Read "p" param for product modal
    case params["p"] do
      nil ->
        # No product in URL, close modal if open
        socket
        |> assign(:editing_product, nil)
        |> assign(:product_edit_form, to_form(Product.changeset(%Product{}, %{})))

      product_id_str ->
        try do
          product_id = String.to_integer(product_id_str)
          # Load the product and open modal
          product = Catalog.get_product_with_images!(product_id)

          # Convert prices from cents to dollars for display
          changes = %{
            "original_price_cents" => format_cents_to_dollars(product.original_price_cents),
            "sale_price_cents" => format_cents_to_dollars(product.sale_price_cents)
          }

          changeset = Product.changeset(product, changes)

          socket
          |> assign(:editing_product, product)
          |> assign(:product_edit_form, to_form(changeset))
          |> assign(:current_edit_image_index, 0)
        rescue
          Ecto.NoResultsError ->
            # Product not found, clear param by redirecting
            push_patch(socket, to: ~p"/products")

          ArgumentError ->
            # Invalid ID format, clear param by redirecting
            push_patch(socket, to: ~p"/products")
        end
    end
  end
end
