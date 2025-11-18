defmodule Pavoi.Catalog do
  @moduledoc """
  The Catalog context handles product management, brands, and product images.
  """

  import Ecto.Query, warn: false
  alias Pavoi.Repo

  alias Pavoi.Catalog.{Brand, Product, ProductImage, ProductVariant}

  ## Brands

  @doc """
  Returns the list of brands.
  """
  def list_brands do
    Repo.all(Brand)
  end

  @doc """
  Gets a single brand.
  Raises `Ecto.NoResultsError` if the Brand does not exist.
  """
  def get_brand!(id), do: Repo.get!(Brand, id)

  @doc """
  Gets a brand by slug.
  """
  def get_brand_by_slug(slug) do
    Repo.get_by(Brand, slug: slug)
  end

  def get_brand_by_slug!(slug) do
    Repo.get_by!(Brand, slug: slug)
  end

  @doc """
  Creates a brand.
  """
  def create_brand(attrs \\ %{}) do
    %Brand{}
    |> Brand.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a brand.
  """
  def update_brand(%Brand{} = brand, attrs) do
    brand
    |> Brand.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a brand.
  """
  def delete_brand(%Brand{} = brand) do
    Repo.delete(brand)
  end

  ## Products

  @doc """
  Returns the list of products with optional filters.
  """
  def list_products(filters \\ []) do
    Product
    |> apply_product_filters(filters)
    |> Repo.all()
  end

  @doc """
  Lists all products with their images preloaded.
  Adds a primary_image virtual field for convenience.
  """
  def list_products_with_images do
    Product
    |> preload(:product_images)
    |> Repo.all()
    |> Enum.map(fn product ->
      primary_image =
        Enum.find(product.product_images, & &1.is_primary) || List.first(product.product_images)

      Map.put(product, :primary_image, primary_image)
    end)
  end

  @doc """
  Lists products for a specific brand with their images preloaded.
  Adds a primary_image virtual field for convenience.
  """
  def list_products_by_brand_with_images(brand_id) do
    Product
    |> where([p], p.brand_id == ^brand_id)
    |> preload(:product_images)
    |> Repo.all()
    |> Enum.map(fn product ->
      primary_image =
        Enum.find(product.product_images, & &1.is_primary) || List.first(product.product_images)

      Map.put(product, :primary_image, primary_image)
    end)
  end

  # Allow-list for safe product sorting
  defp build_order_by(sort_by) do
    case sort_by do
      "price_asc" -> [asc: :original_price_cents]
      "price_desc" -> [desc: :original_price_cents]
      "name" -> [asc: :name]
      # Default/blank: sort by name
      "" -> [asc: :name]
      # Fallback for invalid values
      _ -> [asc: :name]
    end
  end

  @doc """
  Searches and paginates products with optional filters.

  ## Options
    - brand_id: Filter by brand ID
    - search_query: Search by product name, SKU, or PID (default: "")
    - exclude_ids: List of product IDs to exclude from results (default: [])
    - page: Current page number (default: 1)
    - per_page: Items per page (default: 20)
    - sort_by: Sort order - "" or "name" (default), "price_asc", "price_desc"

  ## Returns
    A map with:
      - products: List of products with primary_image field
      - total: Total count of matching products
      - page: Current page number
      - per_page: Items per page
      - has_more: Boolean indicating if more products are available
  """
  def search_products_paginated(opts \\ []) do
    brand_id = Keyword.get(opts, :brand_id)
    search_query = Keyword.get(opts, :search_query, "")
    exclude_ids = Keyword.get(opts, :exclude_ids, [])
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 20)
    sort_by = Keyword.get(opts, :sort_by, "")

    # Build base query
    query = from(p in Product, preload: :product_images)

    # Filter by brand if provided
    query =
      if brand_id do
        where(query, [p], p.brand_id == ^brand_id)
      else
        query
      end

    # Apply search filter if query provided
    query =
      if search_query != "" do
        search_pattern = "%#{search_query}%"

        where(
          query,
          [p],
          ilike(p.name, ^search_pattern) or
            ilike(p.sku, ^search_pattern) or
            ilike(p.pid, ^search_pattern)
        )
      else
        query
      end

    # Exclude products if IDs provided
    query =
      if Enum.empty?(exclude_ids) do
        query
      else
        where(query, [p], p.id not in ^exclude_ids)
      end

    # Get total count
    total = Repo.aggregate(query, :count)

    # Get paginated results with dynamic sorting
    order_by_clause = build_order_by(sort_by)

    products =
      query
      |> order_by(^order_by_clause)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()
      |> add_primary_image_virtual_field()

    %{
      products: products,
      total: total,
      page: page,
      per_page: per_page,
      has_more: total > page * per_page
    }
  end

  defp add_primary_image_virtual_field(products) do
    Enum.map(products, fn product ->
      primary_image =
        Enum.find(product.product_images, & &1.is_primary) || List.first(product.product_images)

      Map.put(product, :primary_image, primary_image)
    end)
  end

  defp apply_product_filters(query, []), do: query

  defp apply_product_filters(query, [{:brand_id, brand_id} | rest]) do
    query
    |> where([p], p.brand_id == ^brand_id)
    |> apply_product_filters(rest)
  end

  defp apply_product_filters(query, [{:preload, preloads} | rest]) do
    query
    |> preload(^preloads)
    |> apply_product_filters(rest)
  end

  defp apply_product_filters(query, [_ | rest]) do
    apply_product_filters(query, rest)
  end

  @doc """
  Gets a single product.
  Returns `{:ok, product}` if found, `nil` if not found.
  """
  def get_product(id) do
    case Repo.get(Product, id) do
      nil -> nil
      product -> {:ok, product}
    end
  end

  @doc """
  Gets a single product.
  Raises `Ecto.NoResultsError` if the Product does not exist.
  """
  def get_product!(id), do: Repo.get!(Product, id)

  @doc """
  Gets a product by Shopify product ID (PID).
  Returns nil if not found.
  """
  def get_product_by_pid(pid) do
    Repo.get_by(Product, pid: pid)
  end

  @doc """
  Gets a product with brand, images, and variants preloaded.
  """
  def get_product_with_images!(id) do
    ordered_images = from(pi in ProductImage, order_by: [asc: pi.position])
    ordered_variants = from(pv in ProductVariant, order_by: [asc: pv.position])

    Product
    |> where([p], p.id == ^id)
    |> preload([
      :brand,
      product_images: ^ordered_images,
      product_variants: ^ordered_variants
    ])
    |> Repo.one!()
  end

  @doc """
  Creates a product.
  """
  def create_product(attrs \\ %{}) do
    %Product{}
    |> Product.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a product.
  """
  def update_product(%Product{} = product, attrs) do
    product
    |> Product.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a product.
  """
  def delete_product(%Product{} = product) do
    Repo.delete(product)
  end

  ## Product Images

  @doc """
  Creates a product image.
  """
  def create_product_image(attrs \\ %{}) do
    product_id = Map.get(attrs, :product_id) || Map.get(attrs, "product_id")

    %ProductImage{}
    |> ProductImage.changeset(attrs)
    |> Ecto.Changeset.put_change(:product_id, product_id)
    |> Repo.insert()
  end

  @doc """
  Updates a product image.
  """
  def update_product_image(%ProductImage{} = image, attrs) do
    image
    |> ProductImage.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a product image.
  """
  def delete_product_image(%ProductImage{} = image) do
    Repo.delete(image)
  end

  @doc """
  Deletes all images for a product.
  """
  def delete_product_images(product_id) do
    from(pi in ProductImage, where: pi.product_id == ^product_id)
    |> Repo.delete_all()
  end

  ## Product Variants

  @doc """
  Creates a product variant.
  """
  def create_product_variant(attrs \\ %{}) do
    %ProductVariant{}
    |> ProductVariant.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a product variant.
  """
  def update_product_variant(%ProductVariant{} = variant, attrs) do
    variant
    |> ProductVariant.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a product variant.
  """
  def delete_product_variant(%ProductVariant{} = variant) do
    Repo.delete(variant)
  end

  @doc """
  Deletes all variants for a product.
  """
  def delete_product_variants(product_id) do
    from(pv in ProductVariant, where: pv.product_id == ^product_id)
    |> Repo.delete_all()
  end

  @doc """
  Gets a product variant by Shopify variant ID.
  Returns nil if not found.
  """
  def get_variant_by_shopify_id(shopify_variant_id) do
    Repo.get_by(ProductVariant, shopify_variant_id: shopify_variant_id)
  end
end
