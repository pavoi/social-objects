defmodule SocialObjects.Workers.ProductPerformanceSyncWorker do
  @moduledoc """
  Oban worker that syncs TikTok Shop product performance data to the products table.

  Runs daily via cron. Fetches 90-day performance metrics from the TikTok Shop
  Analytics API and updates products with GMV, items sold, and orders.

  ## Matching Algorithm

  Matches API product IDs to local products via `tiktok_product_id` field.

  ## Rate Limit Handling

  Uses exponential backoff with streak tracking (like CreatorEnrichmentWorker):
  - Checks cooldown before executing
  - Records rate limit streak on 429 errors
  - Calculates backoff: 15min, 30min, 60min, 2hrs max
  - Resets streak on successful sync

  ## Edge Cases

  - No product match: Skipped (product may not be synced yet)
  - API rate limit (429): Records streak, snoozes with exponential backoff
  - API server error (5xx): Returns error for Oban retry
  """

  use Oban.Worker,
    queue: :analytics,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing]]

  require Logger

  alias SocialObjects.Catalog
  alias SocialObjects.Settings
  alias SocialObjects.TiktokShop.Analytics
  alias SocialObjects.TiktokShop.Parsers

  # Cooldown period in seconds after a rate limit before allowing new requests
  @cooldown_seconds 10 * 60

  @doc """
  Performs the product performance sync for a brand.

  Checks rate limit cooldown before executing. If in cooldown, skips execution.
  Fetches the last 90 days of product performance data and updates products.
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"brand_id" => brand_id}}) do
    case check_rate_limit_cooldown(brand_id) do
      {:cooldown, seconds_remaining} ->
        Logger.info(
          "[ProductPerformance] In cooldown (#{seconds_remaining}s remaining), skipping"
        )

        :ok

      :ok ->
        do_perform(brand_id)
    end
  end

  defp do_perform(brand_id) do
    _ =
      Phoenix.PubSub.broadcast(
        SocialObjects.PubSub,
        "product_performance:sync:#{brand_id}",
        {:product_performance_sync_started}
      )

    case sync_products(brand_id) do
      {:ok, stats} ->
        # Reset rate limit streak on success
        _ = Settings.reset_product_performance_rate_limit_streak(brand_id)
        # Update the system_settings timestamp for the dashboard
        _ = Settings.update_product_performance_last_sync_at(brand_id)

        _ =
          Phoenix.PubSub.broadcast(
            SocialObjects.PubSub,
            "product_performance:sync:#{brand_id}",
            {:product_performance_sync_completed, stats}
          )

        Logger.info(
          "[ProductPerformance] Sync completed for brand #{brand_id}: " <>
            "#{stats.products_synced} synced, #{stats.products_skipped} skipped " <>
            "(#{stats.api_products_count} from API, #{stats.local_products_count} local)"
        )

        :ok

      {:snooze, seconds} ->
        {:snooze, seconds}

      {:error, reason} ->
        _ =
          Phoenix.PubSub.broadcast(
            SocialObjects.PubSub,
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

        stats =
          Map.merge(stats, %{
            api_products_count: length(api_products),
            local_products_count: map_size(product_lookup)
          })

        {:ok, stats}

      {:error, reason} when reason == :rate_limited or elem(reason, 0) == :rate_limited ->
        streak = Settings.record_product_performance_rate_limit(brand_id)
        backoff = calculate_backoff(streak)

        Logger.warning(
          "[ProductPerformance] Rate limited (streak: #{streak}), backing off #{div(backoff, 60)} min"
        )

        {:snooze, backoff}

      {:error, reason} ->
        Logger.error("[ProductPerformance] Failed to fetch analytics: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp check_rate_limit_cooldown(brand_id) do
    case Settings.get_product_performance_last_rate_limited_at(brand_id) do
      nil ->
        :ok

      last_limited_at ->
        seconds_since = DateTime.diff(DateTime.utc_now(), last_limited_at, :second)

        if seconds_since < @cooldown_seconds do
          {:cooldown, @cooldown_seconds - seconds_since}
        else
          :ok
        end
    end
  end

  defp calculate_backoff(streak) do
    # Base: 15 minutes, doubles each streak up to 2 hours max
    base = 15 * 60
    max_backoff = 2 * 60 * 60
    # Cap the multiplier at streak 3 (8x = 2 hours)
    multiplier = :math.pow(2, min(streak - 1, 3)) |> round()
    min(base * multiplier, max_backoff)
  end

  defp fetch_all_products(brand_id, start_date, end_date) do
    fetch_all_pages(brand_id, start_date, end_date, nil, [])
  end

  defp fetch_all_pages(brand_id, start_date, end_date, page_token, acc) do
    opts = build_page_opts(start_date, end_date, page_token)

    Analytics.get_shop_product_performance_list(brand_id, opts)
    |> handle_fetch_page_response(brand_id, start_date, end_date, acc)
  end

  defp build_page_opts(start_date, end_date, page_token) do
    base_opts = [
      start_date_ge: start_date,
      end_date_lt: end_date,
      page_size: page_size(),
      sort_field: "gmv",
      sort_order: "DESC"
    ]

    if page_token, do: Keyword.put(base_opts, :page_token, page_token), else: base_opts
  end

  defp handle_fetch_page_response(
         {:ok, %{"data" => data}},
         brand_id,
         start_date,
         end_date,
         acc
       )
       when is_map(data) do
    products = Map.get(data, "shop_products", [])
    next_token = Map.get(data, "next_page_token")
    all_products = acc ++ products

    maybe_log_api_sample(acc, products)
    maybe_fetch_next_page(next_token, brand_id, start_date, end_date, all_products)
  end

  defp handle_fetch_page_response(
         {:ok, %{"data" => nil}},
         _brand_id,
         _start_date,
         _end_date,
         acc
       ) do
    {:ok, acc}
  end

  defp handle_fetch_page_response(
         {:ok, %{"data" => data}},
         _brand_id,
         _start_date,
         _end_date,
         acc
       ) do
    Logger.warning("Unexpected product performance data payload: #{inspect(data, limit: 80)}")
    {:ok, acc}
  end

  defp handle_fetch_page_response(
         {:ok, %{"code" => 429}},
         _brand_id,
         _start_date,
         _end_date,
         _acc
       ) do
    {:error, :rate_limited}
  end

  defp handle_fetch_page_response(
         {:ok, %{"code" => code}},
         _brand_id,
         _start_date,
         _end_date,
         _acc
       )
       when code >= 500 do
    {:error, {:server_error, code}}
  end

  defp handle_fetch_page_response(
         {:ok, %{"code" => code, "message" => message}},
         _brand_id,
         _start_date,
         _end_date,
         _acc
       )
       when code != 0 do
    Logger.error("TikTok product performance API error: code=#{code}, message=#{message}")
    {:error, {:api_error, code, message}}
  end

  defp handle_fetch_page_response({:ok, response}, _brand_id, _start_date, _end_date, _acc) do
    Logger.error("Unexpected TikTok product performance API response: #{inspect(response)}")
    {:error, {:unexpected_response, response}}
  end

  defp handle_fetch_page_response({:error, reason}, _brand_id, _start_date, _end_date, _acc) do
    {:error, reason}
  end

  defp maybe_log_api_sample([], [sample | _]) do
    sample_keys = Map.keys(sample)

    Logger.debug(
      "TikTok product performance API sample - keys: #{inspect(sample_keys)}, " <>
        "id: #{inspect(sample["id"])}, product_id: #{inspect(sample["product_id"])}"
    )
  end

  defp maybe_log_api_sample(_acc, _products), do: :ok

  defp maybe_fetch_next_page(next_token, brand_id, start_date, end_date, all_products)
       when is_binary(next_token) and next_token != "" do
    fetch_all_pages(brand_id, start_date, end_date, next_token, all_products)
  end

  defp maybe_fetch_next_page(_next_token, _brand_id, _start_date, _end_date, all_products) do
    {:ok, all_products}
  end

  defp page_size do
    Application.get_env(:social_objects, :worker_tuning, [])
    |> Keyword.get(:product_performance_sync, [])
    |> Keyword.get(:page_size, 100)
  end

  defp process_products(product_lookup, api_products) do
    synced_at = DateTime.utc_now() |> DateTime.truncate(:second)
    stats = %{products_synced: 0, products_skipped: 0}

    Enum.reduce(api_products, stats, fn api_product, acc ->
      process_single_product(product_lookup, api_product, synced_at, acc)
    end)
  end

  defp process_single_product(product_lookup, api_product, synced_at, acc) do
    # TikTok API may return product ID as "id" or "product_id" depending on endpoint version
    tiktok_id = api_product["id"] || api_product["product_id"]

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
