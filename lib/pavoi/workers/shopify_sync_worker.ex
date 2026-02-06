defmodule Pavoi.Workers.ShopifySyncWorker do
  @moduledoc """
  Oban worker that syncs Shopify product catalog to Pavoi database.

  Runs daily via cron to keep product data in sync.

  ## Field Ownership Strategy

  Product fields are categorized into two groups:

  ### Shopify-Synced Fields (Overwritten on Each Sync)
  These fields are automatically updated from Shopify API on every sync:
  - `pid` - Shopify product ID
  - `name` - Product title
  - `description` - Product description (HTML)
  - `original_price_cents` - Minimum variant price
  - `sale_price_cents` - Minimum compare-at price
  - `sku` - First variant SKU
  - `brand_id` - Set to the current brand

  ### User-Editable Fields (Never Overwritten)
  These fields are managed by users and never synced from Shopify:
  - `talking_points_md` - Host talking points (set to nil during sync to preserve existing values)

  ### Images and Variants
  Product images and variants are fully replaced on each sync (DELETE all, INSERT new).
  However, certain image fields are user-editable and preserved:
  - `alt_text` - Custom accessibility text
  - `thumbnail_path` - Custom thumbnail override
  - `is_primary` - Primary image flag
  """

  use Oban.Worker,
    queue: :shopify,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing]]

  require Logger
  alias Pavoi.Catalog
  alias Pavoi.Catalog.SizeExtractor
  alias Pavoi.Repo
  alias Pavoi.Settings
  alias Pavoi.Shopify.Client

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case resolve_brand_id(Map.get(args, "brand_id")) do
      {:ok, brand_id} ->
        Logger.info("Starting Shopify product sync...")

        # Broadcast sync start event
        Phoenix.PubSub.broadcast(Pavoi.PubSub, "shopify:sync:#{brand_id}", {:sync_started})

        case sync_all_products(brand_id) do
          {:ok, counts} ->
            Logger.info("""
            ✅ Shopify sync completed successfully
               - Products synced: #{counts.products}
               - Images synced: #{counts.images}
            """)

            # Update last sync timestamp
            Settings.update_shopify_last_sync_at(brand_id)

            # Broadcast sync complete event
            Phoenix.PubSub.broadcast(
              Pavoi.PubSub,
              "shopify:sync:#{brand_id}",
              {:sync_completed, counts}
            )

            :ok

          {:error, :rate_limited} ->
            Logger.warning("Rate limited by Shopify API, will retry")
            # Broadcast sync failed event
            Phoenix.PubSub.broadcast(
              Pavoi.PubSub,
              "shopify:sync:#{brand_id}",
              {:sync_failed, :rate_limited}
            )

            {:snooze, 60}

          {:error, reason} ->
            Logger.error("Shopify sync failed: #{inspect(reason)}")
            # Broadcast sync failed event
            Phoenix.PubSub.broadcast(
              Pavoi.PubSub,
              "shopify:sync:#{brand_id}",
              {:sync_failed, reason}
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("[ShopifySync] Failed to resolve brand_id: #{inspect(reason)}")
        {:discard, reason}
    end
  end

  @doc """
  Syncs all products from Shopify to the local database.

  Returns:
    - `{:ok, %{products: count, images: count}}` on success
    - `{:error, reason}` on failure
  """
  def sync_all_products(brand_id) do
    case Client.fetch_all_products(brand_id) do
      {:ok, shopify_products} ->
        Logger.info("Fetched #{length(shopify_products)} products from Shopify")

        # Filter out products with invalid pricing (0 or nil)
        valid_products =
          Enum.filter(shopify_products, fn product ->
            variants = product["variants"]["nodes"] || []
            min_price = get_minimum_variant_price(variants)
            min_price != nil && min_price > 0
          end)

        Logger.info(
          "Filtered to #{length(valid_products)} products with valid pricing (skipped #{length(shopify_products) - length(valid_products)} products)"
        )

        counts = %{products: 0, images: 0}

        result =
          Enum.reduce_while(valid_products, {:ok, counts}, fn shopify_product, {:ok, acc} ->
            sync_and_accumulate(brand_id, shopify_product, acc)
          end)

        finalize_sync_result(result)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sync_and_accumulate(brand_id, shopify_product, acc) do
    case sync_product(brand_id, shopify_product) do
      {:ok, image_count} ->
        {:cont, {:ok, %{acc | products: acc.products + 1, images: acc.images + image_count}}}

      {:error, reason} ->
        Logger.error("Failed to sync product #{shopify_product["id"]}: #{inspect(reason)}")
        {:halt, {:error, reason}}
    end
  end

  defp finalize_sync_result({:ok, final_counts}), do: {:ok, final_counts}

  defp finalize_sync_result(error), do: error

  defp sync_product(brand_id, shopify_product) do
    Repo.transaction(fn ->
      # Parse variants data
      variants = shopify_product["variants"]["nodes"] || []
      images = shopify_product["images"]["nodes"] || []

      # Build product attributes
      # NOTE: We only include Shopify-synced fields here. User-editable fields like
      # talking_points_md are intentionally omitted to preserve existing values.
      product_attrs = %{
        pid: shopify_product["id"],
        name: shopify_product["title"],
        description: shopify_product["descriptionHtml"],
        original_price_cents: get_minimum_variant_price(variants),
        sale_price_cents: get_minimum_compare_at_price(variants),
        sku: get_first_variant_sku(variants)
      }

      # Upsert product (update if exists, insert if new)
      product = upsert_product(brand_id, product_attrs)

      # Sync images
      sync_images(product, images)

      # Sync variants
      sync_variants(product, variants)

      # Return image count
      length(images)
    end)
  end

  defp upsert_product(brand_id, attrs) do
    case Catalog.get_product_by_pid(brand_id, attrs.pid) do
      nil ->
        Logger.debug("Creating new product: #{attrs.name}")

        case Catalog.create_product(brand_id, attrs) do
          {:ok, product} ->
            product

          {:error, changeset} ->
            Logger.error("Failed to create product #{attrs.name}: #{inspect(changeset.errors)}")
            raise "Failed to create product: #{attrs.name}"
        end

      existing_product ->
        Logger.debug("Updating existing product: #{attrs.name}")

        case Catalog.update_product(existing_product, attrs) do
          {:ok, product} ->
            product

          {:error, changeset} ->
            Logger.error("Failed to update product #{attrs.name}: #{inspect(changeset.errors)}")
            raise "Failed to update product: #{attrs.name}"
        end
    end
  end

  defp sync_images(product, shopify_images) do
    # Delete existing images
    Catalog.delete_product_images(product.id)

    # Create new images
    Enum.with_index(shopify_images, fn image, index ->
      case Catalog.create_product_image(%{
             product_id: product.id,
             path: image["url"],
             thumbnail_path: nil,
             position: index,
             is_primary: index == 0
           }) do
        {:ok, product_image} ->
          product_image

        {:error, changeset} ->
          Logger.error(
            "Failed to create product image for #{product.name} at position #{index}: #{inspect(changeset.errors)}"
          )

          raise "Failed to create product image"
      end
    end)
  end

  defp sync_variants(product, shopify_variants) do
    # Delete existing variants
    Catalog.delete_product_variants(product.id)

    # Create new variants with size extraction
    variants =
      Enum.with_index(shopify_variants, fn variant, index ->
        # Convert selectedOptions array to a map
        selected_options =
          (variant["selectedOptions"] || [])
          |> Enum.map(fn opt -> {opt["name"], opt["value"]} end)
          |> Enum.into(%{})

        # Extract size from multiple sources (including product name as fallback)
        {size, size_type, size_source} =
          SizeExtractor.extract_size(
            selected_options: selected_options,
            sku: variant["sku"],
            name: variant["title"],
            product_name: product.name
          )

        case Catalog.create_product_variant(%{
               product_id: product.id,
               shopify_variant_id: variant["id"],
               title: variant["title"],
               sku: variant["sku"],
               price_cents: parse_price_to_cents(variant["price"]),
               compare_at_price_cents: parse_compare_at_price(variant["compareAtPrice"]),
               barcode: variant["barcode"],
               position: index,
               selected_options: selected_options,
               size: size,
               size_type: size_type && to_string(size_type),
               size_source: size_source && to_string(size_source)
             }) do
          {:ok, product_variant} ->
            product_variant

          {:error, changeset} ->
            Logger.error(
              "Failed to create product variant for #{product.name} (#{variant["title"]}): #{inspect(changeset.errors)}"
            )

            raise "Failed to create product variant"
        end
      end)

    # Update product size_range after all variants created
    update_product_size_range(product, variants)

    variants
  end

  defp update_product_size_range(product, variants) do
    size_range = SizeExtractor.compute_size_range(variants)
    sizes_with_values = Enum.filter(variants, & &1.size)
    has_size_variants = length(sizes_with_values) > 1

    case Catalog.update_product(product, %{
           size_range: size_range,
           has_size_variants: has_size_variants
         }) do
      {:ok, _updated_product} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "Failed to update product size_range for #{product.name}: #{inspect(changeset.errors)}"
        )
    end
  end

  # Price conversion functions

  @doc """
  Parses Shopify price string to cents.

  ## Examples

      iex> parse_price_to_cents("13.95")
      1395

      iex> parse_price_to_cents("0.00")
      0

      iex> parse_price_to_cents(nil)
      nil
  """
  def parse_price_to_cents(price_string) when is_binary(price_string) do
    {price_float, _} = Float.parse(price_string)
    round(price_float * 100)
  end

  def parse_price_to_cents(nil), do: nil

  @doc """
  Parses Shopify compareAt price, treating 0 as nil (no sale).
  """
  def parse_compare_at_price(price_string) when is_binary(price_string) do
    case parse_price_to_cents(price_string) do
      0 -> nil
      cents -> cents
    end
  end

  def parse_compare_at_price(nil), do: nil

  @doc """
  Gets minimum price across all variants.

  Pavoi stores a single price per product, so we use the minimum
  variant price to avoid showing higher than available.
  """
  def get_minimum_variant_price([]), do: nil

  def get_minimum_variant_price(variants) do
    variants
    |> Enum.map(& &1["price"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&parse_price_to_cents/1)
    |> Enum.min(fn -> nil end)
  end

  @doc """
  Gets minimum compareAtPrice across variants that have sales.

  Returns nil if no variants have compareAtPrice (or all are 0).
  """
  def get_minimum_compare_at_price([]), do: nil

  def get_minimum_compare_at_price(variants) do
    compare_prices =
      variants
      |> Enum.map(& &1["compareAtPrice"])
      |> Enum.map(&parse_compare_at_price/1)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(compare_prices) do
      nil
    else
      Enum.min(compare_prices)
    end
  end

  @doc """
  Gets SKU from first variant.
  """
  def get_first_variant_sku([]), do: nil
  def get_first_variant_sku([first | _rest]), do: first["sku"]

  defp normalize_brand_id(brand_id) when is_integer(brand_id), do: brand_id

  defp normalize_brand_id(brand_id) when is_binary(brand_id) do
    String.to_integer(brand_id)
  end

  defp resolve_brand_id(nil) do
    {:error, :brand_id_required}
  end

  defp resolve_brand_id(brand_id), do: {:ok, normalize_brand_id(brand_id)}
end
