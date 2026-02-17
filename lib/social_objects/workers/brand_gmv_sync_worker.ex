defmodule SocialObjects.Workers.BrandGmvSyncWorker do
  @moduledoc """
  Oban worker that syncs brand-specific GMV from TikTok video/live analytics.

  Runs daily via cron. Fetches 30-day rolling performance data from TikTok Shop
  Analytics API and updates BrandCreator records with content GMV values.

  ## Data Flow

  1. Fetch all video performance (paginated, 30-day window)
  2. Fetch all live performance (paginated, 30-day window)
  3. Group by username
  4. For each username:
     - Match to creator (exact username OR previous_usernames)
     - If no match: auto-create creator with username
     - Aggregate video_gmv + live_gmv
  5. Update BrandCreator with:
     - Current rolling values
     - Delta-accumulated cumulative values
  6. Create CreatorPerformanceSnapshot for historical tracking

  ## Rate Limiting

  - 300ms delay between API calls (existing pattern)
  - Exponential backoff on 429s (snooze for 5 minutes)
  - Process in batches with pagination

  ## Usage

  Manual trigger:
      SocialObjects.Workers.BrandGmvSyncWorker.new(%{"brand_id" => 1}) |> Oban.insert()

  Test synchronously:
      SocialObjects.Workers.BrandGmvSyncWorker.perform(%Oban.Job{args: %{"brand_id" => 1}})
  """

  use Oban.Worker,
    queue: :analytics,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing]]

  require Logger

  alias SocialObjects.Creators.BrandGmv
  alias SocialObjects.Settings

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"brand_id" => brand_id}}) do
    # Broadcast sync started
    _ = broadcast(brand_id, {:brand_gmv_sync_started})

    case BrandGmv.sync_from_analytics(brand_id) do
      {:ok, stats} ->
        # Record timestamp before PubSub broadcast
        _ = Settings.update_brand_gmv_last_sync_at(brand_id)
        _ = broadcast(brand_id, {:brand_gmv_sync_completed, stats})

        Logger.info(
          "[BrandGmvSyncWorker] Completed for brand #{brand_id}: " <>
            "#{stats.usernames_processed} usernames, " <>
            "#{stats.creators_matched} matched, " <>
            "#{stats.creators_created} created, " <>
            "#{stats.brand_creators_updated} updated"
        )

        :ok

      {:error, :rate_limited} ->
        Logger.warning("[BrandGmvSyncWorker] Rate limited for brand #{brand_id}, snoozing 5 min")
        _ = broadcast(brand_id, {:brand_gmv_sync_failed, :rate_limited})
        {:snooze, 300}

      {:error, :no_auth_record} ->
        Logger.warning("[BrandGmvSyncWorker] No TikTok auth for brand #{brand_id}")
        _ = broadcast(brand_id, {:brand_gmv_sync_failed, :no_auth_record})
        {:discard, :no_auth_record}

      {:error, reason} ->
        Logger.error("[BrandGmvSyncWorker] Failed for brand #{brand_id}: #{inspect(reason)}")
        _ = broadcast(brand_id, {:brand_gmv_sync_failed, reason})
        {:error, reason}
    end
  end

  defp broadcast(brand_id, message) do
    Phoenix.PubSub.broadcast(
      SocialObjects.PubSub,
      "brand_gmv:sync:#{brand_id}",
      message
    )
  end
end
