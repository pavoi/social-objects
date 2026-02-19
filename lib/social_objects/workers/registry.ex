defmodule SocialObjects.Workers.Registry do
  @moduledoc """
  Central worker metadata registry defining all background workers with their
  configuration, schedules, and capabilities.

  This registry provides a single source of truth for:
  - Worker metadata (name, description, category)
  - Schedule information (cron-like descriptions)
  - Queue assignments
  - Status tracking keys (system_settings)
  - Manual trigger capabilities
  """

  @workers [
    # Products
    %{
      key: :shopify_sync,
      module: SocialObjects.Workers.ShopifySyncWorker,
      name: "Shopify Sync",
      description: "Syncs products from Shopify catalog",
      category: :products,
      schedule: "Daily @ 12 AM",
      queue: :shopify,
      status_key: "shopify_last_sync_at",
      triggerable: true,
      brand_scoped: true,
      requirements: [hard: :shopify],
      freshness_mode: :scheduled
    },
    %{
      key: :tiktok_sync,
      module: SocialObjects.Workers.TiktokSyncWorker,
      name: "TikTok Shop Sync",
      description: "Syncs products from TikTok Shop",
      category: :products,
      schedule: "Daily @ 12 AM",
      queue: :tiktok,
      status_key: "tiktok_last_sync_at",
      triggerable: true,
      brand_scoped: true,
      requirements: [hard: :tiktok_auth],
      freshness_mode: :scheduled
    },
    %{
      key: :product_performance_sync,
      module: SocialObjects.Workers.ProductPerformanceSyncWorker,
      name: "Product Performance",
      description: "Syncs product performance metrics",
      category: :products,
      schedule: "Every 2 days @ 5 AM",
      queue: :tiktok,
      status_key: "product_performance_last_sync_at",
      triggerable: true,
      brand_scoped: true,
      requirements: [hard: :tiktok_auth],
      freshness_mode: :scheduled
    },
    %{
      key: :brand_gmv_sync,
      module: SocialObjects.Workers.BrandGmvSyncWorker,
      name: "Brand GMV Sync",
      description: "Syncs brand-specific content GMV from TikTok",
      category: :products,
      schedule: "Daily @ 6 AM",
      queue: :tiktok,
      status_key: "brand_gmv_last_sync_at",
      triggerable: true,
      brand_scoped: true,
      requirements: [hard: :tiktok_auth],
      freshness_mode: :scheduled
    },

    # Creators
    %{
      key: :bigquery_order_sync,
      module: SocialObjects.Workers.BigQueryOrderSyncWorker,
      name: "BigQuery Orders",
      description: "Syncs shop orders from BigQuery",
      category: :creators,
      schedule: "Daily @ 12 AM",
      queue: :bigquery,
      status_key: "bigquery_last_sync_at",
      triggerable: true,
      brand_scoped: true,
      requirements: [hard: :bigquery],
      freshness_mode: :scheduled
    },
    %{
      key: :creator_enrichment,
      module: SocialObjects.Workers.CreatorEnrichmentWorker,
      name: "Creator Enrichment",
      description: "Enriches creator profiles from TikTok API",
      category: :creators,
      schedule: "Every hour",
      queue: :enrichment,
      status_key: "enrichment_last_sync_at",
      triggerable: true,
      brand_scoped: true,
      requirements: [hard: :tiktok_auth],
      freshness_mode: :scheduled
    },
    %{
      key: :video_sync,
      module: SocialObjects.Workers.VideoSyncWorker,
      name: "Video Sync",
      description: "Syncs creator video performance data",
      category: :creators,
      schedule: "Daily @ 4 AM",
      queue: :video_sync,
      status_key: "videos_last_import_at",
      triggerable: true,
      brand_scoped: true,
      requirements: [hard: :tiktok_auth],
      freshness_mode: :scheduled
    },
    %{
      key: :creator_import,
      module: SocialObjects.Workers.CreatorImportWorker,
      name: "Creator Import",
      description: "Imports creators from external sources",
      category: :creators,
      schedule: "On demand",
      queue: :default,
      status_key: nil,
      triggerable: false,
      brand_scoped: true,
      requirements: [],
      freshness_mode: :on_demand
    },
    %{
      key: :euka_import,
      module: SocialObjects.Workers.CreatorImportWorker,
      name: "Euka Import",
      description: "Imports creator data from Euka exports",
      category: :creators,
      schedule: "On demand",
      queue: :creators,
      status_key: "external_import_last_at",
      triggerable: false,
      brand_scoped: true,
      requirements: [],
      freshness_mode: :on_demand
    },
    %{
      key: :creator_outreach,
      module: SocialObjects.Workers.CreatorOutreachWorker,
      name: "Creator Outreach",
      description: "Sends outreach emails to creators",
      category: :creators,
      schedule: "On demand",
      queue: :default,
      status_key: nil,
      triggerable: false,
      brand_scoped: true,
      requirements: [],
      freshness_mode: :on_demand
    },
    %{
      key: :creator_purchase_sync,
      module: SocialObjects.Workers.CreatorPurchaseSyncWorker,
      name: "Creator Purchases",
      description: "Syncs creator sample purchases",
      category: :creators,
      schedule: "Daily @ 3 AM",
      queue: :tiktok,
      status_key: "creator_purchase_last_sync_at",
      triggerable: true,
      brand_scoped: true,
      requirements: [hard: :tiktok_auth],
      freshness_mode: :scheduled
    },

    # Streaming
    %{
      key: :tiktok_live_monitor,
      module: SocialObjects.Workers.TiktokLiveMonitorWorker,
      name: "Live Monitor",
      description: "Scans for active TikTok live streams",
      category: :streaming,
      schedule: "Every 2 min",
      queue: :tiktok_live,
      status_key: "tiktok_live_last_scan_at",
      triggerable: true,
      brand_scoped: true,
      # Note: Live monitor only needs live accounts configured, NOT TikTok Shop auth
      requirements: [hard: :live_accounts],
      freshness_mode: :scheduled
    },
    %{
      key: :tiktok_live_stream,
      module: SocialObjects.Workers.TiktokLiveStreamWorker,
      name: "Stream Capture",
      description: "Captures live stream data in real-time",
      category: :streaming,
      schedule: "On demand",
      queue: :tiktok_live,
      status_key: "stream_capture_last_run_at",
      triggerable: false,
      brand_scoped: true,
      requirements: [],
      freshness_mode: :on_demand
    },
    %{
      key: :stream_analytics_sync,
      module: SocialObjects.Workers.StreamAnalyticsSyncWorker,
      name: "Stream Analytics",
      description: "Syncs stream analytics from TikTok",
      category: :streaming,
      schedule: "Daily @ 6 AM",
      queue: :tiktok,
      status_key: "stream_analytics_last_sync_at",
      triggerable: true,
      brand_scoped: true,
      requirements: [hard: :tiktok_auth],
      freshness_mode: :scheduled
    },
    %{
      key: :stream_report,
      module: SocialObjects.Workers.StreamReportWorker,
      name: "Stream Report",
      description: "Generates and sends stream reports to Slack",
      category: :streaming,
      schedule: "On demand",
      queue: :default,
      status_key: "stream_report_last_sent_at",
      triggerable: false,
      brand_scoped: true,
      requirements: [],
      freshness_mode: :on_demand
    },
    %{
      key: :weekly_stream_recap,
      module: SocialObjects.Workers.WeeklyStreamRecapWorker,
      name: "Weekly Recap",
      description: "Sends weekly stream recap to Slack (previous week)",
      category: :streaming,
      schedule: "Mon 9 AM PST",
      queue: :default,
      status_key: "weekly_recap_last_sent_at",
      triggerable: true,
      brand_scoped: true,
      requirements: [],
      freshness_mode: :weekly,
      # Explicit override (matches default for :weekly mode)
      max_staleness_hours: 192
    },

    # Utilities
    %{
      key: :tiktok_token_refresh,
      module: SocialObjects.Workers.TiktokTokenRefreshWorker,
      name: "Token Refresh",
      description: "Refreshes TikTok API access tokens",
      category: :utilities,
      schedule: "Daily @ 3 AM",
      queue: :default,
      status_key: "token_refresh_last_run_at",
      triggerable: true,
      brand_scoped: true,
      requirements: [hard: :tiktok_auth],
      freshness_mode: :scheduled
    },
    %{
      key: :talking_points,
      module: SocialObjects.Workers.TalkingPointsWorker,
      name: "Talking Points",
      description: "Generates AI talking points for products",
      category: :utilities,
      schedule: "On demand",
      queue: :ai,
      status_key: "talking_points_last_run_at",
      triggerable: false,
      brand_scoped: true,
      requirements: [],
      freshness_mode: :on_demand
    },
    %{
      key: :gmv_backfill,
      module: SocialObjects.Workers.GmvBackfillWorker,
      name: "GMV Backfill",
      description: "Backfills GMV data for historical streams",
      category: :utilities,
      schedule: "On demand",
      queue: :tiktok,
      status_key: "gmv_backfill_last_run_at",
      triggerable: true,
      brand_scoped: true,
      # Soft requirement - worker will no-op gracefully if missing
      requirements: [soft: :tiktok_auth],
      freshness_mode: :on_demand
    }
  ]

  @category_labels %{
    products: "Product Syncs",
    creators: "Creator & CRM",
    streaming: "Live Streaming",
    utilities: "Utilities"
  }

  @category_order [:products, :creators, :streaming, :utilities]

  @doc """
  Returns all worker definitions.
  """
  def all_workers, do: @workers

  @doc """
  Returns workers grouped by category in display order.
  """
  def workers_by_category do
    @category_order
    |> Enum.map(fn category ->
      workers = Enum.filter(@workers, fn w -> w.category == category end)
      {category, workers}
    end)
  end

  @doc """
  Returns only workers that can be manually triggered.
  """
  def triggerable_workers do
    Enum.filter(@workers, fn w -> w.triggerable end)
  end

  @doc """
  Gets a single worker by key.
  """
  def get_worker(key) when is_atom(key) do
    Enum.find(@workers, fn w -> w.key == key end)
  end

  def get_worker(key) when is_binary(key) do
    get_worker(String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  @doc """
  Returns the human-readable label for a category.
  """
  def category_label(category), do: Map.get(@category_labels, category, "Other")

  @doc """
  Returns ordered list of categories.
  """
  def categories, do: @category_order
end
