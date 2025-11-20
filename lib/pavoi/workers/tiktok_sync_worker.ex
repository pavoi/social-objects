defmodule Pavoi.Workers.TiktokSyncWorker do
  @moduledoc """
  Oban worker that syncs TikTok Shop product catalog to Pavoi database.

  Runs hourly via cron to keep product data in sync with TikTok Shop.

  ## Sync Strategy

  Products are matched with existing Shopify products by SKU at the variant level:
  - TikTok Shop `seller_sku` matches against `product_variants.sku`
  - If match found: Update existing product with TikTok data
  - If no match: Create new product marked as TikTok-only

  ## Platform-Specific Pricing

  TikTok pricing is stored separately from Shopify pricing:
  - `tiktok_price_cents` and `tiktok_compare_at_price_cents` on variants
  - Primary display price (`price_cents`) remains Shopify-sourced when available
  - For TikTok-only products, TikTok pricing becomes the display price

  ## Pagination

  TikTok API returns products in pages with `next_page_token`.
  The sync fetches all pages until no more tokens are returned.
  """

  use Oban.Worker, queue: :tiktok, max_attempts: 3

  require Logger
  import Ecto.Query
  alias Pavoi.Catalog
  alias Pavoi.Repo
  alias Pavoi.Settings
  alias Pavoi.TiktokShop

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("Starting TikTok Shop product sync...")

    # Broadcast sync start event
    Phoenix.PubSub.broadcast(Pavoi.PubSub, "tiktok:sync", {:tiktok_sync_started})

    case sync_all_products() do
      {:ok, counts} ->
        Logger.info("""
        ✅ TikTok Shop sync completed successfully
           - Products synced: #{counts.products}
           - Variants synced: #{counts.variants}
           - New products created: #{counts.new_products}
           - Matched with Shopify: #{counts.matched}
        """)

        # Update last sync timestamp
        Settings.update_tiktok_last_sync_at()

        # Broadcast sync complete event
        Phoenix.PubSub.broadcast(Pavoi.PubSub, "tiktok:sync", {:tiktok_sync_completed, counts})

        :ok

      {:error, :rate_limited} ->
        Logger.warning("Rate limited by TikTok Shop API, will retry")

        Phoenix.PubSub.broadcast(
          Pavoi.PubSub,
          "tiktok:sync",
          {:tiktok_sync_failed, :rate_limited}
        )

        {:snooze, 60}

      {:error, reason} ->
        Logger.error("TikTok Shop sync failed: #{inspect(reason)}")
        Phoenix.PubSub.broadcast(Pavoi.PubSub, "tiktok:sync", {:tiktok_sync_failed, reason})
        {:error, reason}
    end
  end

  @doc """
  Syncs all products from TikTok Shop to the local database.

  Handles pagination by following `next_page_token` until all products are fetched.

  Returns:
    - `{:ok, %{products: count, variants: count, new_products: count, matched: count}}` on success
    - `{:error, reason}` on failure
  """
  def sync_all_products do
    counts = %{products: 0, variants: 0, new_products: 0, matched: 0}

    case fetch_all_products_with_pagination() do
      {:ok, tiktok_products} ->
        Logger.info("Fetched #{length(tiktok_products)} products from TikTok Shop")

        # Filter out products with invalid pricing (0 or nil)
        valid_products =
          Enum.filter(tiktok_products, fn product ->
            skus = product["skus"] || []
            min_price = get_minimum_sku_price(skus)
            min_price != nil && min_price > 0
          end)

        Logger.info(
          "Filtered to #{length(valid_products)} products with valid pricing (skipped #{length(tiktok_products) - length(valid_products)} products)"
        )

        result =
          Enum.reduce_while(valid_products, {:ok, counts}, fn tiktok_product, {:ok, acc} ->
            sync_and_accumulate(tiktok_product, acc)
          end)

        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_all_products_with_pagination(page_token \\ nil, accumulated_products \\ []) do
    # Build query parameters with pagination
    params = %{page_size: 10}
    params = if page_token, do: Map.put(params, :page_token, page_token), else: params

    case TiktokShop.make_api_request(:post, "/product/202309/products/search", params, %{}) do
      {:ok, %{"data" => %{"products" => products, "next_page_token" => next_token}}}
      when not is_nil(next_token) and next_token != "" ->
        # More pages available, fetch next page
        Logger.debug("Fetched page with #{length(products)} products, continuing...")
        fetch_all_products_with_pagination(next_token, accumulated_products ++ products)

      {:ok, %{"data" => %{"products" => products}}} ->
        # Last page or only page
        Logger.debug("Fetched final page with #{length(products)} products")
        {:ok, accumulated_products ++ products}

      {:ok, response} ->
        Logger.error("Unexpected TikTok API response structure: #{inspect(response)}")
        {:error, :unexpected_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_product_details(tiktok_product_id) do
    case TiktokShop.make_api_request(:get, "/product/202309/products/#{tiktok_product_id}", %{}) do
      {:ok, %{"data" => product_data}} ->
        {:ok, product_data}

      {:ok, response} ->
        Logger.error("Unexpected TikTok API response for product #{tiktok_product_id}: #{inspect(response)}")
        {:error, :unexpected_response}

      {:error, reason} ->
        Logger.error("Failed to fetch product details for #{tiktok_product_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp sync_and_accumulate(tiktok_product, acc) do
    case sync_product(tiktok_product) do
      {:ok, {variant_count, is_new, is_matched}} ->
        new_acc = %{
          acc
          | products: acc.products + 1,
            variants: acc.variants + variant_count,
            new_products: acc.new_products + if(is_new, do: 1, else: 0),
            matched: acc.matched + if(is_matched, do: 1, else: 0)
        }

        {:cont, {:ok, new_acc}}

      {:error, reason} ->
        Logger.error("Failed to sync TikTok product #{tiktok_product["id"]}: #{inspect(reason)}")

        {:halt, {:error, reason}}
    end
  end

  defp sync_product(tiktok_product) do
    Repo.transaction(fn ->
      tiktok_product_id = tiktok_product["id"]
      tiktok_title = tiktok_product["title"]
      tiktok_skus = tiktok_product["skus"] || []

      # Try to find matching product by matching any SKU
      {matching_product, _matching_variant, is_matched} = find_matching_product(tiktok_skus)

      # Sync product and variant data
      {product, result} =
        if matching_product do
          # Update existing product with TikTok data
          result = update_existing_product(matching_product, tiktok_product_id, tiktok_skus, is_matched)
          {matching_product, result}
        else
          # Create new TikTok-only product
          result = create_tiktok_only_product(tiktok_product_id, tiktok_title, tiktok_skus)
          # Fetch the newly created product
          product = Catalog.get_product_by_tiktok_product_id(tiktok_product_id)
          {product, result}
        end

      # Fetch product details to get images
      case fetch_product_details(tiktok_product_id) do
        {:ok, product_data} ->
          # Sync product images
          sync_product_images(product, product_data, is_matched)

        {:error, reason} ->
          Logger.warning(
            "Failed to fetch details for product #{tiktok_product_id}, skipping images: #{inspect(reason)}"
          )
      end

      # Return the original result tuple
      result
    end)
  end

  defp find_matching_product(tiktok_skus) do
    seller_skus = Enum.map(tiktok_skus, & &1["seller_sku"]) |> Enum.reject(&is_nil/1)

    if Enum.empty?(seller_skus) do
      {nil, nil, false}
    else
      # Query for the first variant matching any of these SKUs
      # If multiple variants match, they should all belong to the same product
      variant =
        from(v in Pavoi.Catalog.ProductVariant,
          where: v.sku in ^seller_skus,
          preload: :product,
          limit: 1
        )
        |> Repo.one()

      case variant do
        nil -> {nil, nil, false}
        variant -> {variant.product, variant, true}
      end
    end
  end

  defp update_existing_product(product, tiktok_product_id, tiktok_skus, is_matched) do
    # Update product with TikTok product ID
    case Catalog.update_product(product, %{tiktok_product_id: tiktok_product_id}) do
      {:ok, updated_product} ->
        # Sync TikTok SKU data to variants
        variant_count = sync_tiktok_skus_to_variants(updated_product, tiktok_skus)
        {variant_count, false, is_matched}

      {:error, changeset} ->
        Logger.error(
          "Failed to update product #{product.id} with TikTok data: #{inspect(changeset.errors)}"
        )

        raise "Failed to update product with TikTok data"
    end
  end

  defp create_tiktok_only_product(tiktok_product_id, tiktok_title, tiktok_skus) do
    # Get or create a default brand for TikTok-only products
    brand = get_or_create_tiktok_brand()

    # Calculate minimum price from TikTok SKUs
    min_price = get_minimum_sku_price(tiktok_skus)

    # Create new product
    product_attrs = %{
      tiktok_product_id: tiktok_product_id,
      name: tiktok_title,
      description: nil,
      original_price_cents: min_price,
      sale_price_cents: nil,
      brand_id: brand.id
    }

    case Catalog.create_product(product_attrs) do
      {:ok, product} ->
        # Create variants from TikTok SKUs
        variant_count = create_variants_from_tiktok_skus(product, tiktok_skus)
        {variant_count, true, false}

      {:error, changeset} ->
        Logger.error(
          "Failed to create TikTok-only product #{tiktok_title}: #{inspect(changeset.errors)}"
        )

        raise "Failed to create TikTok-only product"
    end
  end

  defp sync_product_images(product, tiktok_product_data, is_matched) do
    if should_skip_tiktok_images?(product, is_matched) do
      Logger.debug("Product #{product.id} has Shopify images, skipping TikTok images")
      :ok
    else
      replace_tiktok_images(product, tiktok_product_data)
    end
  end

  defp should_skip_tiktok_images?(product, is_matched) do
    return_val = is_matched && has_shopify_images?(product)
    return_val
  end

  defp has_shopify_images?(product) do
    existing_images = Repo.preload(product, :product_images).product_images
    Enum.any?(existing_images, &is_nil(&1.tiktok_uri))
  end

  defp replace_tiktok_images(product, tiktok_product_data) do
    delete_existing_tiktok_images(product.id)

    main_images = get_in(tiktok_product_data, ["main_images"]) || []

    main_images
    |> Enum.with_index()
    |> Enum.each(fn {image_data, index} ->
      create_product_image_from_tiktok(product.id, image_data, index)
    end)

    :ok
  end

  defp delete_existing_tiktok_images(product_id) do
    from(pi in Pavoi.Catalog.ProductImage,
      where: pi.product_id == ^product_id and not is_nil(pi.tiktok_uri)
    )
    |> Repo.delete_all()
  end

  defp create_product_image_from_tiktok(product_id, image_data, index) do
    urls = image_data["urls"] || []
    thumb_urls = image_data["thumb_urls"] || []
    tiktok_uri = image_data["uri"]

    if Enum.empty?(urls) do
      :skip
    else
      image_attrs = %{
        product_id: product_id,
        path: List.first(urls),
        thumbnail_path: List.first(thumb_urls),
        tiktok_uri: tiktok_uri,
        is_primary: index == 0,
        position: index
      }

      case Catalog.create_product_image(image_attrs) do
        {:ok, _image} ->
          Logger.debug("Created image for product #{product_id}, position #{index}")

        {:error, changeset} ->
          Logger.error(
            "Failed to create image for product #{product_id}: #{inspect(changeset.errors)}"
          )
      end
    end
  end

  defp sync_tiktok_skus_to_variants(product, tiktok_skus) do
    product_id = product.id

    Enum.reduce(tiktok_skus, 0, fn tiktok_sku, count ->
      update_variant_from_tiktok_sku(product_id, tiktok_sku, count)
    end)
  end

  defp update_variant_from_tiktok_sku(product_id, tiktok_sku, count) do
    seller_sku = tiktok_sku["seller_sku"]
    tiktok_sku_id = tiktok_sku["id"]

    # Find matching variant by SKU
    variant =
      from(v in Pavoi.Catalog.ProductVariant,
        where: v.product_id == ^product_id and v.sku == ^seller_sku
      )
      |> Repo.one()

    case variant do
      nil ->
        Logger.debug("No matching variant found for TikTok SKU #{seller_sku}")
        count

      variant ->
        update_variant_with_tiktok_data(variant, tiktok_sku_id, tiktok_sku, count)
    end
  end

  defp update_variant_with_tiktok_data(variant, tiktok_sku_id, tiktok_sku, count) do
    tiktok_attrs = %{
      tiktok_sku_id: tiktok_sku_id,
      tiktok_price_cents: parse_tiktok_price(tiktok_sku["price"]),
      tiktok_compare_at_price_cents: nil
    }

    case Catalog.update_product_variant(variant, tiktok_attrs) do
      {:ok, _} ->
        count + 1

      {:error, changeset} ->
        Logger.error(
          "Failed to update variant #{variant.id} with TikTok SKU data: #{inspect(changeset.errors)}"
        )

        count
    end
  end

  defp create_variants_from_tiktok_skus(product, tiktok_skus) do
    tiktok_skus
    |> Enum.with_index()
    |> Enum.reduce(0, fn {tiktok_sku, index}, count ->
      variant_attrs = %{
        product_id: product.id,
        tiktok_sku_id: tiktok_sku["id"],
        title: tiktok_sku["seller_sku"] || "Variant #{index + 1}",
        sku: tiktok_sku["seller_sku"],
        price_cents: parse_tiktok_price(tiktok_sku["price"]),
        compare_at_price_cents: nil,
        tiktok_price_cents: parse_tiktok_price(tiktok_sku["price"]),
        tiktok_compare_at_price_cents: nil,
        position: index,
        selected_options: %{}
      }

      case Catalog.create_product_variant(variant_attrs) do
        {:ok, _} ->
          count + 1

        {:error, changeset} ->
          Logger.error(
            "Failed to create TikTok variant for #{tiktok_sku["seller_sku"]}: #{inspect(changeset.errors)}"
          )

          count
      end
    end)
  end

  defp get_or_create_tiktok_brand do
    slug = "tiktok-shop"

    case Catalog.get_brand_by_slug(slug) do
      nil ->
        Logger.info("Creating TikTok Shop brand")

        case Catalog.create_brand(%{name: "TikTok Shop", slug: slug}) do
          {:ok, brand} ->
            brand

          {:error, changeset} ->
            Logger.error("Failed to create TikTok Shop brand: #{inspect(changeset.errors)}")
            raise "Failed to create TikTok Shop brand"
        end

      brand ->
        brand
    end
  end

  defp get_minimum_sku_price([]), do: nil

  defp get_minimum_sku_price(skus) do
    skus
    |> Enum.map(& &1["price"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&parse_tiktok_price/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
  end

  defp parse_tiktok_price(%{"tax_exclusive_price" => price_str, "currency" => _currency})
       when is_binary(price_str) do
    # TikTok prices come as {"tax_exclusive_price": "16.95", "currency": "USD"}
    case Float.parse(price_str) do
      {price_float, _} -> round(price_float * 100)
      :error -> nil
    end
  end

  defp parse_tiktok_price(_), do: nil
end
