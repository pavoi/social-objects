defmodule Pavoi.Workers.TiktokSyncWorker do
  @moduledoc """
  Oban worker that syncs TikTok Shop product catalog to Pavoi database.

  Runs daily via cron to keep product data in sync with TikTok Shop.

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

  use Oban.Worker,
    queue: :tiktok,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing]]

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

    with {:ok, tiktok_products} <- fetch_all_products_with_pagination(),
         _ <- Logger.info("Fetched #{length(tiktok_products)} products from TikTok Shop"),
         valid_products <- filter_products_with_valid_pricing(tiktok_products),
         {:ok, final_counts, products_needing_images} <-
           sync_products_phase1(valid_products, counts) do
      images_synced = sync_images_in_parallel(products_needing_images)
      Logger.info("Images synced for #{images_synced} products")
      {:ok, final_counts}
    end
  end

  defp filter_products_with_valid_pricing(products) do
    valid =
      Enum.filter(products, fn product ->
        skus = product["skus"] || []
        min_price = get_minimum_sku_price(skus)
        min_price != nil && min_price > 0
      end)

    Logger.info(
      "Filtered to #{length(valid)} products with valid pricing (skipped #{length(products) - length(valid)} products)"
    )

    valid
  end

  defp sync_products_phase1(valid_products, counts) do
    initial_state = {:ok, counts, []}
    total = length(valid_products)

    valid_products
    |> Enum.with_index(1)
    |> Enum.reduce_while(initial_state, fn {tiktok_product, index}, {:ok, acc, image_queue} ->
      log_sync_progress(index, total)
      sync_and_accumulate(tiktok_product, acc, image_queue)
    end)
  end

  defp log_sync_progress(index, total) when rem(index, 100) == 0 do
    Logger.info("Syncing product #{index}/#{total}...")
  end

  defp log_sync_progress(_index, _total), do: :ok

  defp fetch_all_products_with_pagination(page_token \\ nil, accumulated_products \\ []) do
    # Build query parameters with pagination (50 is a good balance for TikTok API)
    params = %{page_size: 50}
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
        Logger.error(
          "Unexpected TikTok API response for product #{tiktok_product_id}: #{inspect(response)}"
        )

        {:error, :unexpected_response}

      {:error, reason} ->
        Logger.error(
          "Failed to fetch product details for #{tiktok_product_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp sync_and_accumulate(tiktok_product, acc, image_queue) do
    case sync_product(tiktok_product) do
      {:ok, {product, tiktok_product_id, needs_images?, variant_count, is_new, is_matched}} ->
        new_acc = %{
          acc
          | products: acc.products + 1,
            variants: acc.variants + variant_count,
            new_products: acc.new_products + if(is_new, do: 1, else: 0),
            matched: acc.matched + if(is_matched, do: 1, else: 0)
        }

        # Queue this product for image sync if needed
        new_image_queue =
          if needs_images? do
            [{product, tiktok_product_id} | image_queue]
          else
            image_queue
          end

        {:cont, {:ok, new_acc, new_image_queue}}

      {:error, reason} ->
        Logger.error("Failed to sync TikTok product #{tiktok_product["id"]}: #{inspect(reason)}")

        {:halt, {:error, reason}}
    end
  end

  defp sync_product(tiktok_product) do
    tiktok_product_id = tiktok_product["id"]
    tiktok_title = tiktok_product["title"]
    tiktok_skus = tiktok_product["skus"] || []

    transaction_result =
      Repo.transaction(fn ->
        # Try to find matching product by matching any SKU
        {matching_product, _matching_variant, is_matched} = find_matching_product(tiktok_skus)

        # Also check for existing product by tiktok_product_id (prevents duplicates)
        existing_tiktok_product = Catalog.get_product_by_tiktok_product_id(tiktok_product_id)

        # Sync product and variant data
        # Priority: SKU match > existing TikTok product > create new
        {product, result} =
          sync_product_data(
            matching_product,
            existing_tiktok_product,
            tiktok_product_id,
            tiktok_title,
            tiktok_skus,
            is_matched
          )

        # Return product info for image sync decision (done later in parallel)
        {product, is_matched, result}
      end)

    case transaction_result do
      {:ok, {product, is_matched, {variant_count, is_new, is_matched_result}}} ->
        # Determine if this product needs TikTok images (will be fetched in parallel later)
        needs_images? = needs_tiktok_details?(product, is_matched)

        {:ok,
         {product, tiktok_product_id, needs_images?, variant_count, is_new, is_matched_result}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp needs_tiktok_details?(product, is_matched) do
    # Fetch TikTok details if:
    # 1. Product needs images (not matched with Shopify or no Shopify images)
    # 2. OR product is missing description
    needs_images = not (is_matched && has_shopify_images?(product))
    missing_description = is_nil(product.description) or product.description == ""

    needs_images or missing_description
  end

  defp sync_images_in_parallel(products_needing_images) do
    # Deduplicate by product_id to avoid race conditions in parallel processing
    # (multiple TikTok products can map to the same local product)
    unique_products =
      products_needing_images
      |> Enum.uniq_by(fn {product, _tiktok_id} -> product.id end)

    count = length(unique_products)

    if count == 0 do
      Logger.info("No products need TikTok image fetching")
      0
    else
      Logger.info("Fetching images for #{count} products in parallel (10 concurrent)...")

      unique_products
      |> Task.async_stream(
        fn {product, tiktok_id} ->
          fetch_and_sync_images(product, tiktok_id)
        end,
        max_concurrency: 10,
        timeout: 30_000,
        on_timeout: :kill_task
      )
      |> Enum.reduce(0, fn
        {:ok, :ok}, acc ->
          acc + 1

        {:ok, {:error, _}}, acc ->
          acc

        {:exit, :timeout}, acc ->
          Logger.warning("Image fetch timed out for a product")
          acc

        _, acc ->
          acc
      end)
    end
  end

  defp fetch_and_sync_images(product, tiktok_product_id) do
    case fetch_product_details(tiktok_product_id) do
      {:ok, product_data} ->
        replace_tiktok_images(product, product_data)
        sync_description_from_tiktok(product, product_data)
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to fetch details for product #{tiktok_product_id}, skipping images: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp sync_description_from_tiktok(product, product_data) do
    # Only update description if product doesn't have one
    if is_nil(product.description) or product.description == "" do
      description = get_in(product_data, ["description"])

      if description && description != "" do
        case Catalog.update_product(product, %{description: description}) do
          {:ok, _updated} ->
            Logger.debug("Updated description for product #{product.id}")

          {:error, changeset} ->
            Logger.warning(
              "Failed to update description for product #{product.id}: #{inspect(changeset.errors)}"
            )
        end
      end
    end
  end

  defp sync_product_data(
         matching_product,
         existing_tiktok_product,
         tiktok_product_id,
         tiktok_title,
         tiktok_skus,
         is_matched
       ) do
    cond do
      matching_product ->
        # SKU match found - update with TikTok data
        result =
          update_existing_product(matching_product, tiktok_product_id, tiktok_skus, is_matched)

        {matching_product, result}

      existing_tiktok_product ->
        # No SKU match, but product already exists by TikTok ID - update it
        result =
          update_existing_product(existing_tiktok_product, tiktok_product_id, tiktok_skus, false)

        {existing_tiktok_product, result}

      true ->
        # No existing product found - create new TikTok-only product
        result = create_tiktok_only_product(tiktok_product_id, tiktok_title, tiktok_skus)
        # Fetch the newly created product
        product = Catalog.get_product_by_tiktok_product_id(tiktok_product_id)
        {product, result}
    end
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

  defp has_shopify_images?(product) do
    existing_images = Repo.preload(product, :product_images).product_images
    Enum.any?(existing_images, &is_nil(&1.tiktok_uri))
  end

  defp replace_tiktok_images(product, tiktok_product_data) do
    delete_existing_tiktok_images(product.id)

    main_images = get_in(tiktok_product_data, ["main_images"]) || []
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    # Check if a primary image already exists (from Shopify)
    has_primary? = has_primary_image?(product.id)

    # Build image records for batch insert
    image_records =
      main_images
      |> Enum.with_index()
      |> Enum.map(fn {image_data, index} ->
        # Only set is_primary if no primary image exists and this is the first image
        is_primary = !has_primary? && index == 0
        build_tiktok_image_attrs(product.id, image_data, index, is_primary, now)
      end)
      |> Enum.reject(&is_nil/1)

    if Enum.any?(image_records) do
      {count, _} = Repo.insert_all(Pavoi.Catalog.ProductImage, image_records)
      Logger.debug("Batch inserted #{count} images for product #{product.id}")
    end

    :ok
  end

  defp has_primary_image?(product_id) do
    from(pi in Pavoi.Catalog.ProductImage,
      where: pi.product_id == ^product_id and pi.is_primary == true,
      limit: 1
    )
    |> Repo.exists?()
  end

  defp delete_existing_tiktok_images(product_id) do
    from(pi in Pavoi.Catalog.ProductImage,
      where: pi.product_id == ^product_id and not is_nil(pi.tiktok_uri)
    )
    |> Repo.delete_all()
  end

  defp build_tiktok_image_attrs(product_id, image_data, index, is_primary, now) do
    urls = image_data["urls"] || []
    thumb_urls = image_data["thumb_urls"] || []
    tiktok_uri = image_data["uri"]

    if Enum.empty?(urls) do
      nil
    else
      %{
        product_id: product_id,
        path: List.first(urls),
        thumbnail_path: List.first(thumb_urls),
        tiktok_uri: tiktok_uri,
        is_primary: is_primary,
        position: index,
        inserted_at: now,
        updated_at: now
      }
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

    # Find matching variant by SKU (limit 1 to handle duplicate SKUs gracefully)
    variant =
      from(v in Pavoi.Catalog.ProductVariant,
        where: v.product_id == ^product_id and v.sku == ^seller_sku,
        limit: 1
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
    cond do
      # Skip if this variant already has this TikTok SKU ID assigned
      variant.tiktok_sku_id == tiktok_sku_id ->
        count + 1

      # Check if another variant already has this TikTok SKU ID
      tiktok_sku_already_assigned?(tiktok_sku_id, variant.id) ->
        Logger.debug(
          "TikTok SKU ID #{tiktok_sku_id} already assigned to another variant, skipping"
        )

        count

      true ->
        apply_tiktok_sku_update(variant, tiktok_sku_id, tiktok_sku, count)
    end
  end

  defp tiktok_sku_already_assigned?(tiktok_sku_id, exclude_variant_id) do
    from(v in Pavoi.Catalog.ProductVariant,
      where: v.tiktok_sku_id == ^tiktok_sku_id and v.id != ^exclude_variant_id,
      limit: 1
    )
    |> Repo.exists?()
  end

  defp apply_tiktok_sku_update(variant, tiktok_sku_id, tiktok_sku, count) do
    tiktok_attrs = %{
      tiktok_sku_id: tiktok_sku_id,
      tiktok_price_cents: parse_tiktok_price(tiktok_sku["price"]),
      tiktok_compare_at_price_cents: nil
    }

    case Catalog.update_product_variant(variant, tiktok_attrs) do
      {:ok, _} ->
        count + 1

      {:error, changeset} ->
        Logger.warning(
          "Skipping variant #{variant.id} TikTok SKU update: #{inspect(changeset.errors)}"
        )

        count
    end
  end

  defp create_variants_from_tiktok_skus(product, tiktok_skus) do
    tiktok_skus
    |> Enum.with_index()
    |> Enum.reduce(0, fn {tiktok_sku, index}, count ->
      seller_sku = tiktok_sku["seller_sku"]
      # Handle both nil and empty string cases for title
      variant_title =
        if seller_sku in [nil, ""], do: "Variant #{index + 1}", else: seller_sku

      variant_attrs = %{
        product_id: product.id,
        tiktok_sku_id: tiktok_sku["id"],
        title: variant_title,
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
    # Use the PAVOI brand for all products (TikTok products are also PAVOI products)
    slug = "pavoi"

    case Catalog.get_brand_by_slug(slug) do
      nil ->
        Logger.info("Creating PAVOI brand for TikTok products")

        case Catalog.create_brand(%{name: "PAVOI", slug: slug}) do
          {:ok, brand} ->
            brand

          {:error, changeset} ->
            Logger.error("Failed to create PAVOI brand: #{inspect(changeset.errors)}")
            raise "Failed to create PAVOI brand"
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
