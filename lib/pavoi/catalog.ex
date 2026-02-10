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
  Gets a single brand.

  Returns nil if the Brand does not exist.
  """
  def get_brand(id), do: Repo.get(Brand, id)

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
  Gets a brand by primary domain.
  """
  def get_brand_by_domain(domain) when is_binary(domain) do
    Repo.get_by(Brand, primary_domain: domain)
  end

  def get_brand_by_domain!(domain) when is_binary(domain) do
    Repo.get_by!(Brand, primary_domain: domain)
  end

  @doc """
  Gets a brand by name.
  """
  def get_brand_by_name(name) do
    Repo.get_by(Brand, name: name)
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

  ## Options
    - `:include_archived` - Include archived products (default: false)
  """
  def list_products(brand_id, filters \\ []) do
    include_archived = Keyword.get(filters, :include_archived, false)

    Product
    |> where([p], p.brand_id == ^brand_id)
    |> maybe_exclude_archived(include_archived)
    |> apply_product_filters(filters)
    |> Repo.all()
  end

  @doc """
  Lists all products with their images preloaded.
  Adds a primary_image virtual field for convenience.

  ## Options
    - `:include_archived` - Include archived products (default: false)
  """
  def list_products_with_images(brand_id, opts \\ []) do
    include_archived = Keyword.get(opts, :include_archived, false)

    Product
    |> where([p], p.brand_id == ^brand_id)
    |> maybe_exclude_archived(include_archived)
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
  def list_products_by_brand_with_images(brand_id), do: list_products_with_images(brand_id)

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
    - search_query: Search by product name, SKU, PID, or TikTok product ID (default: "")
    - exclude_ids: List of product IDs to exclude from results (default: [])
    - page: Current page number (default: 1)
    - per_page: Items per page (default: 20)
    - sort_by: Sort order - "" or "name" (default), "price_asc", "price_desc"
    - platform_filter: Filter by platform - "" (all), "shopify", "tiktok" (default: "")
    - include_archived: Include archived products (default: false)

  ## Returns
    A map with:
      - products: List of products with primary_image field
      - total: Total count of matching products
      - page: Current page number
      - per_page: Items per page
      - has_more: Boolean indicating if more products are available
  """
  def search_products_paginated(brand_id, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 20)
    sort_by = Keyword.get(opts, :sort_by, "")
    include_archived = Keyword.get(opts, :include_archived, false)

    # Build and filter query
    query =
      from(p in Product, preload: :product_images)
      |> where([p], p.brand_id == ^brand_id)
      |> maybe_exclude_archived(include_archived)
      |> apply_platform_filter(Keyword.get(opts, :platform_filter, ""))
      |> apply_search_filter(Keyword.get(opts, :search_query, ""))
      |> apply_exclude_ids_filter(Keyword.get(opts, :exclude_ids, []))

    # Get total count and paginated results
    total = Repo.aggregate(query, :count)
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

  defp apply_platform_filter(query, "shopify"), do: where(query, [p], not is_nil(p.pid))

  defp apply_platform_filter(query, "tiktok"),
    do: where(query, [p], not is_nil(p.tiktok_product_id))

  defp apply_platform_filter(query, _), do: query

  defp apply_search_filter(query, ""), do: query

  defp apply_search_filter(query, search_query) do
    search_pattern = "%#{search_query}%"

    where(
      query,
      [p],
      ilike(p.name, ^search_pattern) or
        ilike(p.sku, ^search_pattern) or
        ilike(p.pid, ^search_pattern) or
        ilike(p.tiktok_product_id, ^search_pattern) or
        ^search_query in p.tiktok_product_ids
    )
  end

  defp apply_exclude_ids_filter(query, []), do: query

  defp apply_exclude_ids_filter(query, exclude_ids),
    do: where(query, [p], p.id not in ^exclude_ids)

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

  # Archive filtering - excludes archived products by default
  defp maybe_exclude_archived(query, true), do: query
  defp maybe_exclude_archived(query, false), do: where(query, [p], is_nil(p.archived_at))

  @doc """
  Gets a single product.
  Returns `{:ok, product}` if found, `nil` if not found.
  """
  def get_product(brand_id, id) do
    case Repo.get_by(Product, id: id, brand_id: brand_id) do
      nil -> nil
      product -> {:ok, product}
    end
  end

  @doc """
  Gets a single product.
  Raises `Ecto.NoResultsError` if the Product does not exist.
  """
  def get_product!(brand_id, id), do: Repo.get_by!(Product, id: id, brand_id: brand_id)

  @doc """
  Gets a product by Shopify product ID (PID).
  Returns nil if not found.
  """
  def get_product_by_pid(brand_id, pid) do
    Repo.get_by(Product, pid: pid, brand_id: brand_id)
  end

  @doc """
  Gets a product by TikTok product ID.
  Returns nil if not found.
  """
  def get_product_by_tiktok_product_id(brand_id, tiktok_product_id) do
    Repo.get_by(Product, tiktok_product_id: tiktok_product_id, brand_id: brand_id)
  end

  @doc """
  Gets multiple products by their Shopify product IDs (PIDs).
  Returns a list of products that match any of the given PIDs.
  """
  def list_products_by_pids(brand_id, pids) when is_list(pids) do
    Product
    |> where([p], p.brand_id == ^brand_id and p.pid in ^pids)
    |> Repo.all()
  end

  @doc """
  Finds products by product IDs (TikTok or Shopify).

  Searches across multiple ID fields:
  - `tiktok_product_id` - Primary TikTok product ID
  - `tiktok_product_ids` - Array of alternate TikTok IDs
  - `pid` - Shopify product ID

  Returns a tuple: `{found_products, not_found_ids}` where:
  - `found_products` is a list of products with :product_images preloaded
  - `not_found_ids` is a list of IDs that didn't match any products

  ## Options
  - `:brand_id` - Filter by brand ID (optional)
  """
  def find_products_by_ids(brand_id, product_ids) when is_list(product_ids) do
    # Build expanded Shopify GID patterns for numeric IDs
    # e.g., "8772010639613" -> "gid://shopify/Product/8772010639613"
    shopify_gid_patterns =
      product_ids
      |> Enum.filter(&numeric_string?/1)
      |> Enum.map(&"gid://shopify/Product/#{&1}")

    all_pid_matches = product_ids ++ shopify_gid_patterns

    # Build query to find products where any ID field matches
    query =
      from(p in Product,
        where:
          p.brand_id == ^brand_id and
            (p.tiktok_product_id in ^product_ids or
               p.pid in ^all_pid_matches or
               fragment("? && ?", p.tiktok_product_ids, ^product_ids)),
        preload: :product_images
      )

    products = Repo.all(query)

    # Build lookup map: input_id -> product (for reordering to match input order)
    product_lookup =
      Enum.reduce(products, %{}, &add_product_to_lookup/2)

    # Reorder products to match input order, deduplicating
    ordered_products =
      product_ids
      |> Enum.reduce({[], MapSet.new()}, &collect_unique_product(&1, &2, product_lookup))
      |> elem(0)
      |> Enum.reverse()
      |> add_primary_image_virtual_field()

    # Build a set of all matched IDs (from all ID fields)
    # Include both the full GID and the numeric portion for Shopify PIDs
    matched_ids =
      Enum.reduce(products, MapSet.new(), fn product, acc ->
        acc
        |> MapSet.put(product.tiktok_product_id)
        |> MapSet.put(product.pid)
        |> MapSet.put(extract_shopify_numeric_id(product.pid))
        |> MapSet.union(MapSet.new(product.tiktok_product_ids || []))
      end)

    # Find which input IDs weren't matched
    not_found_ids =
      product_ids
      |> Enum.reject(&MapSet.member?(matched_ids, &1))

    {ordered_products, not_found_ids}
  end

  # Helper to add a product to the lookup map keyed by all its ID fields
  defp add_product_to_lookup(product, acc) do
    acc
    |> Map.put(product.tiktok_product_id, product)
    |> Map.put(product.pid, product)
    |> Map.put(extract_shopify_numeric_id(product.pid), product)
    |> add_tiktok_ids_to_lookup(product)
  end

  defp add_tiktok_ids_to_lookup(acc, product) do
    Enum.reduce(product.tiktok_product_ids || [], acc, fn id, m ->
      Map.put(m, id, product)
    end)
  end

  # Helper for reordering products to match input order while deduplicating
  defp collect_unique_product(id, {list, seen}, product_lookup) do
    with product when not is_nil(product) <- Map.get(product_lookup, id),
         false <- MapSet.member?(seen, product.id) do
      {[product | list], MapSet.put(seen, product.id)}
    else
      _ -> {list, seen}
    end
  end

  # Check if a string contains only digits
  defp numeric_string?(str) when is_binary(str) do
    String.match?(str, ~r/^\d+$/)
  end

  defp numeric_string?(_), do: false

  # Extract the numeric ID from a Shopify GID like "gid://shopify/Product/8772010639613"
  defp extract_shopify_numeric_id(nil), do: nil

  defp extract_shopify_numeric_id(gid) when is_binary(gid) do
    case String.split(gid, "/") do
      [_, _, _, _, id] -> id
      _ -> nil
    end
  end

  @doc """
  Finds a product by SKU with partial matching.

  Returns the first product where the database SKU contains the search SKU.
  This handles cases where Google Sheets has shortened SKUs.

  Returns nil if no match found.
  """
  def find_product_by_sku(brand_id, sku) when is_binary(sku) do
    Product
    |> where([p], p.brand_id == ^brand_id and ilike(p.sku, ^"%#{sku}%"))
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Gets a product with brand, images, and variants preloaded.
  """
  def get_product_with_images!(brand_id, id) do
    ordered_images = from(pi in ProductImage, order_by: [asc: pi.position])
    ordered_variants = from(pv in ProductVariant, order_by: [asc: pv.position])

    Product
    |> where([p], p.id == ^id and p.brand_id == ^brand_id)
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
  def create_product(brand_id, attrs \\ %{}) do
    %Product{brand_id: brand_id}
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

  @doc """
  Archives a product with a reason.

  Valid reasons: "shopify_filter_excluded", "manual"
  """
  def archive_product(%Product{} = product, reason) do
    product
    |> Product.changeset(%{archived_at: DateTime.utc_now(), archive_reason: reason})
    |> Repo.update()
  end

  @doc """
  Unarchives a product, clearing the archive status.
  """
  def unarchive_product(%Product{} = product) do
    product
    |> Product.changeset(%{archived_at: nil, archive_reason: nil})
    |> Repo.update()
  end

  @doc """
  Updates a product's TikTok performance metrics.

  Used by ProductPerformanceSyncWorker to sync GMV, items sold, and orders.
  """
  def update_product_performance(%Product{} = product, attrs) do
    product
    |> Product.performance_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Returns a map of tiktok_product_id -> product for all products with a TikTok ID.

  Used by ProductPerformanceSyncWorker to efficiently match API data to products.
  """
  def get_products_by_tiktok_ids(brand_id) do
    Product
    |> where([p], p.brand_id == ^brand_id and not is_nil(p.tiktok_product_id))
    |> Repo.all()
    |> Enum.reduce(%{}, fn p, acc -> Map.put(acc, p.tiktok_product_id, p) end)
  end

  @doc """
  Returns all archived products for a brand.
  """
  def list_archived_products(brand_id) do
    Product
    |> where([p], p.brand_id == ^brand_id and not is_nil(p.archived_at))
    |> Repo.all()
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
