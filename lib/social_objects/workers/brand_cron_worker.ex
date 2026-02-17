defmodule SocialObjects.Workers.BrandCronWorker do
  @moduledoc """
  Enqueues per-brand background jobs for scheduled cron tasks.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  alias SocialObjects.Catalog
  alias SocialObjects.Settings
  alias SocialObjects.TiktokShop

  alias SocialObjects.Workers.{
    BigQueryOrderSyncWorker,
    BrandGmvSyncWorker,
    CreatorEnrichmentWorker,
    ProductPerformanceSyncWorker,
    ShopifySyncWorker,
    StreamAnalyticsSyncWorker,
    TiktokLiveMonitorWorker,
    TiktokSyncWorker,
    TiktokTokenRefreshWorker,
    VideoSyncWorker,
    WeeklyStreamRecapWorker
  }

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task" => task}}) do
    Catalog.list_brands()
    |> Enum.each(&enqueue_for_brand(task, &1.id))

    :ok
  end

  defp enqueue_for_brand("shopify_sync", brand_id) do
    if Settings.shopify_configured?(brand_id) do
      %{"brand_id" => brand_id}
      |> ShopifySyncWorker.new()
      |> Oban.insert()
    else
      :ok
    end
  end

  defp enqueue_for_brand("tiktok_sync", brand_id) do
    # Only enqueue if brand has TikTok Shop auth configured
    if TiktokShop.get_auth(brand_id) do
      %{"brand_id" => brand_id}
      |> TiktokSyncWorker.new()
      |> Oban.insert()
    else
      :ok
    end
  end

  defp enqueue_for_brand("bigquery_sync", brand_id) do
    if Settings.bigquery_configured?(brand_id) do
      %{"brand_id" => brand_id, "source" => "cron"}
      |> BigQueryOrderSyncWorker.new()
      |> Oban.insert()
    else
      :ok
    end
  end

  defp enqueue_for_brand("tiktok_token_refresh", brand_id) do
    # Only enqueue if brand has TikTok Shop auth configured
    if TiktokShop.get_auth(brand_id) do
      %{"brand_id" => brand_id}
      |> TiktokTokenRefreshWorker.new()
      |> Oban.insert()
    else
      :ok
    end
  end

  defp enqueue_for_brand("tiktok_live_monitor", brand_id) do
    # Only enqueue if brand has TikTok live accounts configured
    if Settings.tiktok_live_accounts_configured?(brand_id) do
      %{"brand_id" => brand_id, "source" => "cron"}
      |> TiktokLiveMonitorWorker.new()
      |> Oban.insert()
    else
      :ok
    end
  end

  defp enqueue_for_brand("creator_enrichment", brand_id) do
    %{"brand_id" => brand_id, "source" => "cron"}
    |> CreatorEnrichmentWorker.new()
    |> Oban.insert()
  end

  defp enqueue_for_brand("stream_analytics_sync", brand_id) do
    # Only enqueue if brand has TikTok Shop auth configured
    if TiktokShop.get_auth(brand_id) do
      %{"brand_id" => brand_id}
      |> StreamAnalyticsSyncWorker.new()
      |> Oban.insert()
    else
      :ok
    end
  end

  defp enqueue_for_brand("weekly_stream_recap", brand_id) do
    %{"brand_id" => brand_id}
    |> WeeklyStreamRecapWorker.new()
    |> Oban.insert()
  end

  defp enqueue_for_brand("video_sync", brand_id) do
    %{"brand_id" => brand_id}
    |> VideoSyncWorker.new()
    |> Oban.insert()
  end

  defp enqueue_for_brand("product_performance_sync", brand_id) do
    # Only enqueue if brand has TikTok Shop auth configured
    if TiktokShop.get_auth(brand_id) do
      %{"brand_id" => brand_id}
      |> ProductPerformanceSyncWorker.new()
      |> Oban.insert()
    else
      :ok
    end
  end

  defp enqueue_for_brand("brand_gmv_sync", brand_id) do
    # Only enqueue if brand has TikTok Shop auth configured
    if TiktokShop.get_auth(brand_id) do
      %{"brand_id" => brand_id}
      |> BrandGmvSyncWorker.new()
      |> Oban.insert()
    else
      :ok
    end
  end

  defp enqueue_for_brand(_task, _brand_id), do: :ok
end
