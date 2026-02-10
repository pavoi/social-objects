defmodule Pavoi.Workers.ProductPerformanceSyncWorker do
  @moduledoc """
  Oban worker that syncs TikTok Shop product performance data to the products table.

  Runs daily via cron. Fetches 90-day performance metrics from the TikTok Shop
  Analytics API and updates products with GMV, items sold, and orders.

  ## Matching Algorithm

  Matches API product IDs to local products via `tiktok_product_id` field.

  ## Edge Cases

  - No product match: Skipped (product may not be synced yet)
  - API rate limit (429): Snoozes for 5 minutes
  - API server error (5xx): Returns error for Oban retry
  """

  use Oban.Worker, queue: :analytics, max_attempts: 3

  require Logger

  alias Pavoi.Catalog
  alias Pavoi.TiktokShop.Analytics
  alias Pavoi.TiktokShop.Parsers

  @doc """
  Performs the product performance sync for a brand.

  Fetches the last 90 days of product performance data and updates products.
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"brand_id" => brand_id}}) do
    Phoenix.PubSub.broadcast(
      Pavoi.PubSub,
      "product_performance:sync:#{brand_id}",
      {:product_performance_sync_started}
    )

    case sync_products(brand_id) do
      {:ok, stats} ->
        Phoenix.PubSub.broadcast(
          Pavoi.PubSub,
          "product_performance:sync:#{brand_id}",
          {:product_performance_sync_completed, stats}
        )

        Logger.info(
          "Product performance sync completed for brand #{brand_id}: " <>
            "#{stats.products_synced} products synced"
        )

        :ok

      {:snooze, seconds} ->
        {:snooze, seconds}

      {:error, reason} ->
        Phoenix.PubSub.broadcast(
          Pavoi.PubSub,
          "product_performance:sync:#{brand_id}",
          {:product_performance_sync_failed, reason}
        )

        {:error, reason}
    end
  end

  defp sync_products(brand_id) do
    # Fetch last 90 days of product performance data
    end_date = Date.utc_today() |> Date.add(1) |> Date.to_iso8601()
    start_date = Date.utc_today() |> Date.add(-90) |> Date.to_iso8601()

    # Build lookup: tiktok_product_id -> product
    product_lookup = Catalog.get_products_by_tiktok_ids(brand_id)

    case fetch_all_products(brand_id, start_date, end_date) do
      {:ok, api_products} ->
        stats = process_products(product_lookup, api_products)
        {:ok, stats}

      {:error, :rate_limited} ->
        Logger.warning("TikTok Analytics API rate limited, snoozing for 5 minutes")
        {:snooze, 300}

      {:error, reason} ->
        Logger.error("Failed to fetch TikTok product analytics: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetch_all_products(brand_id, start_date, end_date) do
    fetch_all_pages(brand_id, start_date, end_date, nil, [])
  end

  defp fetch_all_pages(brand_id, start_date, end_date, page_token, acc) do
    opts = [
      start_date_ge: start_date,
      end_date_lt: end_date,
      page_size: 100,
      sort_field: "gmv",
      sort_order: "DESC"
    ]

    opts = if page_token, do: Keyword.put(opts, :page_token, page_token), else: opts

    case Analytics.get_shop_product_performance_list(brand_id, opts) do
      {:ok, %{"data" => data}} ->
        products = Map.get(data, "shop_products", [])
        next_token = Map.get(data, "next_page_token")
        all_products = acc ++ products

        if next_token && next_token != "" do
          fetch_all_pages(brand_id, start_date, end_date, next_token, all_products)
        else
          {:ok, all_products}
        end

      {:ok, %{"code" => 429}} ->
        {:error, :rate_limited}

      {:ok, %{"code" => code}} when code >= 500 ->
        {:error, {:server_error, code}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_products(product_lookup, api_products) do
    synced_at = DateTime.utc_now() |> DateTime.truncate(:second)
    stats = %{products_synced: 0, products_skipped: 0}

    Enum.reduce(api_products, stats, fn api_product, acc ->
      process_single_product(product_lookup, api_product, synced_at, acc)
    end)
  end

  defp process_single_product(product_lookup, api_product, synced_at, acc) do
    tiktok_id = api_product["id"]

    case Map.get(product_lookup, tiktok_id) do
      nil ->
        %{acc | products_skipped: acc.products_skipped + 1}

      product ->
        update_product_performance(product, api_product, synced_at, acc)
    end
  end

  defp update_product_performance(product, api_product, synced_at, acc) do
    overall = api_product["overall_performance"] || %{}

    attrs = %{
      gmv_cents: Parsers.parse_gmv_cents(overall["gmv"], default: 0),
      items_sold: Parsers.parse_integer(overall["items_sold"], default: 0),
      orders: Parsers.parse_integer(overall["orders"], default: 0),
      performance_synced_at: synced_at
    }

    case Catalog.update_product_performance(product, attrs) do
      {:ok, _product} ->
        %{acc | products_synced: acc.products_synced + 1}

      {:error, reason} ->
        Logger.warning(
          "Failed to update product performance for #{product.id}: #{inspect(reason)}"
        )

        acc
    end
  end
end
