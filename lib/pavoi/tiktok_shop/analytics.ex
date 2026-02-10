defmodule Pavoi.TiktokShop.Analytics do
  @moduledoc """
  TikTok Shop Analytics API integration.

  Provides access to shop performance, LIVE stream analytics, video performance,
  and product/SKU performance data from TikTok Shop's Analytics API.

  Required scope: data.shop_analytics.public.read
  """

  alias Pavoi.TiktokShop

  # =============================================================================
  # Shop Performance
  # =============================================================================

  @doc """
  Returns performance metrics at shop/seller level.

  ## Options
    - start_date_ge: Start date (ISO 8601 YYYY-MM-DD format), required
    - end_date_lt: End date (ISO 8601 YYYY-MM-DD format), required
    - granularity: "ALL" (aggregate) or "1D" (daily), default: "ALL"
    - currency: "USD" or "LOCAL", default: "LOCAL"

  ## Example
      get_shop_performance(brand_id, start_date_ge: "2026-02-01", end_date_lt: "2026-02-09")
  """
  def get_shop_performance(brand_id, opts \\ []) do
    params = build_date_params(opts)
    params = maybe_add_param(params, :granularity, Keyword.get(opts, :granularity))
    params = maybe_add_param(params, :currency, Keyword.get(opts, :currency, "USD"))

    TiktokShop.make_api_request(brand_id, :get, "/analytics/202509/shop/performance", params)
  end

  @doc """
  Returns daily performance broken down by hour, within 30 days.
  Including today.

  ## Options
    - date: Date in YYYY-MM-DD format, required
    - currency: "USD" or "LOCAL", default: "LOCAL"

  ## Example
      get_shop_performance_per_hour(brand_id, date: "2026-02-08")
  """
  def get_shop_performance_per_hour(brand_id, opts \\ []) do
    date = Keyword.fetch!(opts, :date)
    params = %{}
    params = maybe_add_param(params, :currency, Keyword.get(opts, :currency, "USD"))

    TiktokShop.make_api_request(
      brand_id,
      :get,
      "/analytics/202510/shop/performance/#{date}/performance_per_hour",
      params
    )
  end

  # =============================================================================
  # LIVE Performance
  # =============================================================================

  @doc """
  Returns a list of LIVE stream sessions and associated metrics for a shop.

  ## Options
    - start_date_ge: Start date (ISO 8601 YYYY-MM-DD), required
    - end_date_lt: End date (ISO 8601 YYYY-MM-DD), required
    - page_size: Number per page (max 100, default 10)
    - page_token: Pagination token
    - sort_field: gmv, products_added, different_products_sold, sku_orders,
                  items_sold, customers, 24h_live_gmv (default: gmv)
    - sort_order: "ASC" or "DESC" (default: DESC)
    - currency: "USD" or "LOCAL"
    - account_type: ALL, OFFICIAL_ACCOUNTS, MARKETING_ACCOUNTS, AFFILIATE_ACCOUNTS

  ## Example
      get_shop_live_performance_list(brand_id, start_date_ge: "2026-01-01", end_date_lt: "2026-02-09")
  """
  def get_shop_live_performance_list(brand_id, opts \\ []) do
    params = build_date_params(opts)
    params = maybe_add_param(params, :page_size, Keyword.get(opts, :page_size))
    params = maybe_add_param(params, :page_token, Keyword.get(opts, :page_token))
    params = maybe_add_param(params, :sort_field, Keyword.get(opts, :sort_field))
    params = maybe_add_param(params, :sort_order, Keyword.get(opts, :sort_order))
    params = maybe_add_param(params, :currency, Keyword.get(opts, :currency, "USD"))
    params = maybe_add_param(params, :account_type, Keyword.get(opts, :account_type))

    TiktokShop.make_api_request(
      brand_id,
      :get,
      "/analytics/202509/shop_lives/performance",
      params
    )
  end

  @doc """
  Returns overall performance metrics for all LIVE stream sessions under a shop.

  ## Options
    - start_date_ge: Start date (ISO 8601 YYYY-MM-DD), required
    - end_date_lt: End date (ISO 8601 YYYY-MM-DD), required
    - today: If true, returns real-time metrics of today (overrides date params)
    - granularity: "ALL" or "1D"
    - currency: "USD" or "LOCAL"
    - account_type: ALL, OFFICIAL_ACCOUNTS, MARKETING_ACCOUNTS, AFFILIATE_ACCOUNTS

  ## Example
      get_shop_live_performance_overview(brand_id, start_date_ge: "2026-01-01", end_date_lt: "2026-02-09")
  """
  def get_shop_live_performance_overview(brand_id, opts \\ []) do
    params = build_date_params(opts)
    params = maybe_add_param(params, :today, Keyword.get(opts, :today))
    params = maybe_add_param(params, :granularity, Keyword.get(opts, :granularity))
    params = maybe_add_param(params, :currency, Keyword.get(opts, :currency, "USD"))
    params = maybe_add_param(params, :account_type, Keyword.get(opts, :account_type))

    TiktokShop.make_api_request(
      brand_id,
      :get,
      "/analytics/202509/shop_lives/overview_performance",
      params
    )
  end

  @doc """
  Returns minute-by-minute performance breakdown for a finished LIVE session.

  Note: Only returns data for live streams hosted by shop official account or marketing account.

  ## Known Issue (as of Feb 2026)

  This endpoint consistently returns HTTP 500 (code 98001001 "internal error") for all
  live sessions. The session-level API (`get_shop_live_performance_list`) works correctly.
  When this fails, the sync worker falls back to order-based GMV data (`gmv_hourly`).

  ## Options
    - live_id: TikTok Shop LIVE session ID, required
    - page_token: Pagination token
    - currency: "USD" or "LOCAL"

  ## Example
      get_shop_live_performance_per_minutes(brand_id, live_id: "7123456789")
  """
  def get_shop_live_performance_per_minutes(brand_id, opts \\ []) do
    live_id = Keyword.fetch!(opts, :live_id)
    params = %{}
    params = maybe_add_param(params, :page_token, Keyword.get(opts, :page_token))
    params = maybe_add_param(params, :currency, Keyword.get(opts, :currency, "USD"))

    TiktokShop.make_api_request(
      brand_id,
      :get,
      "/analytics/202510/shop_lives/#{live_id}/performance_per_minutes",
      params
    )
  end

  @doc """
  Returns sale performance of each product during a LIVE session.

  Works for official account & marketing accounts.

  ## Options
    - live_id: TikTok Shop LIVE session ID, required
    - sort_field: direct_gmv, items_sold, customers, created_sku_orders,
                  sku_orders, main_orders, product_impressions, produt_clicks (default: gmv)
    - sort_order: "ASC" or "DESC" (default: DESC)
    - currency: "USD" or "LOCAL"

  ## Example
      get_shop_live_products_performance(brand_id, live_id: "7123456789")
  """
  def get_shop_live_products_performance(brand_id, opts \\ []) do
    live_id = Keyword.fetch!(opts, :live_id)
    params = %{}
    params = maybe_add_param(params, :sort_field, Keyword.get(opts, :sort_field))
    params = maybe_add_param(params, :sort_order, Keyword.get(opts, :sort_order))
    params = maybe_add_param(params, :currency, Keyword.get(opts, :currency, "USD"))

    TiktokShop.make_api_request(
      brand_id,
      :get,
      "/analytics/202512/shop/#{live_id}/products_performance",
      params
    )
  end

  # =============================================================================
  # Video Performance
  # =============================================================================

  @doc """
  Returns a list of videos and associated metrics for a shop.

  ## Options
    - start_date_ge: Start date (ISO 8601 YYYY-MM-DD), required
    - end_date_lt: End date (ISO 8601 YYYY-MM-DD), required
    - page_size: Number per page (max 100, default 10)
    - page_token: Pagination token
    - sort_field: gmv, gpm, avg_customers, sku_orders, items_sold, views,
                  click_through_rate (default: gmv)
    - sort_order: "ASC" or "DESC" (default: DESC)
    - currency: "USD" or "LOCAL"
    - account_type: ALL, OFFICIAL_ACCOUNTS, MARKETING_ACCOUNTS, AFFILIATE_ACCOUNTS

  ## Example
      get_shop_video_performance_list(brand_id, start_date_ge: "2026-01-01", end_date_lt: "2026-02-09")
  """
  def get_shop_video_performance_list(brand_id, opts \\ []) do
    params = build_date_params(opts)
    params = maybe_add_param(params, :page_size, Keyword.get(opts, :page_size))
    params = maybe_add_param(params, :page_token, Keyword.get(opts, :page_token))
    params = maybe_add_param(params, :sort_field, Keyword.get(opts, :sort_field))
    params = maybe_add_param(params, :sort_order, Keyword.get(opts, :sort_order))
    params = maybe_add_param(params, :currency, Keyword.get(opts, :currency, "USD"))
    params = maybe_add_param(params, :account_type, Keyword.get(opts, :account_type))

    TiktokShop.make_api_request(
      brand_id,
      :get,
      "/analytics/202509/shop_videos/performance",
      params
    )
  end

  @doc """
  Returns overall performance metrics for all videos under a shop.

  ## Options
    - start_date_ge: Start date (ISO 8601 YYYY-MM-DD), required
    - end_date_lt: End date (ISO 8601 YYYY-MM-DD), required
    - today: If true, returns real-time metrics of today
    - granularity: "ALL" or "1D"
    - currency: "USD" or "LOCAL"
    - account_type: ALL, OFFICIAL_ACCOUNTS, MARKETING_ACCOUNTS, AFFILIATE_ACCOUNTS

  ## Example
      get_shop_video_performance_overview(brand_id, start_date_ge: "2026-01-01", end_date_lt: "2026-02-09")
  """
  def get_shop_video_performance_overview(brand_id, opts \\ []) do
    params = build_date_params(opts)
    params = maybe_add_param(params, :today, Keyword.get(opts, :today))
    params = maybe_add_param(params, :granularity, Keyword.get(opts, :granularity))
    params = maybe_add_param(params, :currency, Keyword.get(opts, :currency, "USD"))
    params = maybe_add_param(params, :account_type, Keyword.get(opts, :account_type))

    TiktokShop.make_api_request(
      brand_id,
      :get,
      "/analytics/202509/shop_videos/overview_performance",
      params
    )
  end

  @doc """
  Returns detailed performance metrics for a specific video.

  ## Options
    - video_id: TikTok video ID, required
    - start_date_ge: Start date (ISO 8601 YYYY-MM-DD), required
    - end_date_lt: End date (ISO 8601 YYYY-MM-DD), required
    - granularity: "ALL" or "1D"
    - currency: "USD" or "LOCAL"

  ## Example
      get_shop_video_performance_details(brand_id, video_id: "7123456789",
        start_date_ge: "2026-01-01", end_date_lt: "2026-02-09")
  """
  def get_shop_video_performance_details(brand_id, opts \\ []) do
    video_id = Keyword.fetch!(opts, :video_id)
    params = build_date_params(opts)
    params = maybe_add_param(params, :granularity, Keyword.get(opts, :granularity))
    params = maybe_add_param(params, :currency, Keyword.get(opts, :currency, "USD"))

    TiktokShop.make_api_request(
      brand_id,
      :get,
      "/analytics/202509/shop_videos/#{video_id}/performance",
      params
    )
  end

  @doc """
  Returns performance metrics for products promoted in a given video.

  ## Options
    - video_id: TikTok video ID, required
    - start_date_ge: Start date (ISO 8601 YYYY-MM-DD), required
    - end_date_lt: End date (ISO 8601 YYYY-MM-DD), required
    - page_size: Number per page (max 100, default 10)
    - page_token: Pagination token
    - sort_field: gmv, units_sold, daily_avg_buyers (default: gmv)
    - sort_order: "ASC" or "DESC" (default: DESC)
    - currency: "USD" or "LOCAL"

  ## Example
      get_shop_video_products_performance(brand_id, video_id: "7123456789",
        start_date_ge: "2026-01-01", end_date_lt: "2026-02-09")
  """
  def get_shop_video_products_performance(brand_id, opts \\ []) do
    video_id = Keyword.fetch!(opts, :video_id)
    params = build_date_params(opts)
    params = maybe_add_param(params, :page_size, Keyword.get(opts, :page_size))
    params = maybe_add_param(params, :page_token, Keyword.get(opts, :page_token))
    params = maybe_add_param(params, :sort_field, Keyword.get(opts, :sort_field))
    params = maybe_add_param(params, :sort_order, Keyword.get(opts, :sort_order))
    params = maybe_add_param(params, :currency, Keyword.get(opts, :currency, "USD"))

    TiktokShop.make_api_request(
      brand_id,
      :get,
      "/analytics/202509/shop_videos/#{video_id}/products/performance",
      params
    )
  end

  # =============================================================================
  # Product Performance
  # =============================================================================

  @doc """
  Returns a list of product performance overview metrics.

  ## Options
    - start_date_ge: Start date (ISO 8601 YYYY-MM-DD), required
    - end_date_lt: End date (ISO 8601 YYYY-MM-DD), required
    - page_size: Number per page (max 100, default 10)
    - page_token: Pagination token
    - sort_field: gmv, items_sold, orders (default: gmv)
    - sort_order: "ASC" or "DESC" (default: DESC)
    - currency: "USD" or "LOCAL"
    - category_filter: List of category IDs
    - product_status_filter: "LIVE", "INACTIVE", or "ALL" (default: ALL)

  ## Example
      get_shop_product_performance_list(brand_id, start_date_ge: "2026-01-01", end_date_lt: "2026-02-09")
  """
  def get_shop_product_performance_list(brand_id, opts \\ []) do
    params = build_date_params(opts)
    params = maybe_add_param(params, :page_size, Keyword.get(opts, :page_size))
    params = maybe_add_param(params, :page_token, Keyword.get(opts, :page_token))
    params = maybe_add_param(params, :sort_field, Keyword.get(opts, :sort_field))
    params = maybe_add_param(params, :sort_order, Keyword.get(opts, :sort_order))
    params = maybe_add_param(params, :currency, Keyword.get(opts, :currency, "USD"))

    params =
      maybe_add_param(params, :product_status_filter, Keyword.get(opts, :product_status_filter))

    # Note: category_filter requires special handling for array params
    params = maybe_add_array_param(params, :category_filter, Keyword.get(opts, :category_filter))

    TiktokShop.make_api_request(
      brand_id,
      :get,
      "/analytics/202509/shop_products/performance",
      params
    )
  end

  @doc """
  Returns detailed performance metrics for a specific product.

  ## Options
    - product_id: TikTok Shop product ID, required
    - start_date_ge: Start date (ISO 8601 YYYY-MM-DD), required
    - end_date_lt: End date (ISO 8601 YYYY-MM-DD), required
    - granularity: "ALL" or "1D"
    - currency: "USD" or "LOCAL"

  ## Example
      get_shop_product_performance_detail(brand_id, product_id: "1234567890",
        start_date_ge: "2026-01-01", end_date_lt: "2026-02-09")
  """
  def get_shop_product_performance_detail(brand_id, opts \\ []) do
    product_id = Keyword.fetch!(opts, :product_id)
    params = build_date_params(opts)
    params = maybe_add_param(params, :granularity, Keyword.get(opts, :granularity))
    params = maybe_add_param(params, :currency, Keyword.get(opts, :currency, "USD"))

    TiktokShop.make_api_request(
      brand_id,
      :get,
      "/analytics/202509/shop_products/#{product_id}/performance",
      params
    )
  end

  # =============================================================================
  # SKU Performance
  # =============================================================================

  @doc """
  Returns a list of SKU performance metrics.

  ## Options
    - start_date_ge: Start date (ISO 8601 YYYY-MM-DD), required
    - end_date_lt: End date (ISO 8601 YYYY-MM-DD), required
    - page_size: Number per page (max 100)
    - page_token: Pagination token
    - sort_field: gmv, sku_orders, units_sold (default: gmv)
    - sort_order: "ASC" or "DESC" (default: DESC)
    - currency: "USD" or "LOCAL"
    - category_filter: List of category IDs
    - product_status_filter: "LIVE", "INACTIVE", or "ALL" (default: ALL)
    - product_ids: List of product IDs to filter SKUs

  ## Example
      get_shop_sku_performance_list(brand_id, start_date_ge: "2026-01-01", end_date_lt: "2026-02-09")
  """
  def get_shop_sku_performance_list(brand_id, opts \\ []) do
    params = build_date_params(opts)
    params = maybe_add_param(params, :page_size, Keyword.get(opts, :page_size))
    params = maybe_add_param(params, :page_token, Keyword.get(opts, :page_token))
    params = maybe_add_param(params, :sort_field, Keyword.get(opts, :sort_field))
    params = maybe_add_param(params, :sort_order, Keyword.get(opts, :sort_order))
    params = maybe_add_param(params, :currency, Keyword.get(opts, :currency, "USD"))

    params =
      maybe_add_param(params, :product_status_filter, Keyword.get(opts, :product_status_filter))

    params = maybe_add_array_param(params, :category_filter, Keyword.get(opts, :category_filter))
    params = maybe_add_array_param(params, :product_ids, Keyword.get(opts, :product_ids))

    TiktokShop.make_api_request(brand_id, :get, "/analytics/202509/shop_skus/performance", params)
  end

  @doc """
  Returns performance metrics for a specific SKU.

  ## Options
    - sku_id: TikTok Shop SKU ID, required
    - start_date_ge: Start date (ISO 8601 YYYY-MM-DD), required
    - end_date_lt: End date (ISO 8601 YYYY-MM-DD), required
    - granularity: "ALL" or "1D"
    - currency: "USD" or "LOCAL"

  ## Example
      get_shop_sku_performance(brand_id, sku_id: "1234567890",
        start_date_ge: "2026-01-01", end_date_lt: "2026-02-09")
  """
  def get_shop_sku_performance(brand_id, opts \\ []) do
    sku_id = Keyword.fetch!(opts, :sku_id)
    params = build_date_params(opts)
    params = maybe_add_param(params, :granularity, Keyword.get(opts, :granularity))
    params = maybe_add_param(params, :currency, Keyword.get(opts, :currency, "USD"))

    TiktokShop.make_api_request(
      brand_id,
      :get,
      "/analytics/202509/shop_skus/#{sku_id}/performance",
      params
    )
  end

  # =============================================================================
  # Private Helpers
  # =============================================================================

  defp build_date_params(opts) do
    %{
      start_date_ge: Keyword.get(opts, :start_date_ge),
      end_date_lt: Keyword.get(opts, :end_date_lt)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: Map.put(params, key, value)

  defp maybe_add_array_param(params, _key, nil), do: params
  defp maybe_add_array_param(params, _key, []), do: params

  defp maybe_add_array_param(params, key, values) when is_list(values) do
    # TikTok API expects array params as comma-separated values
    Map.put(params, key, Enum.join(values, ","))
  end
end
