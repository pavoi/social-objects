defmodule SocialObjects.Workers.ThumbnailBackfillWorker do
  @moduledoc """
  Oban worker that backfills video thumbnails to Railway storage.

  Migrates existing videos that have thumbnail URLs but no storage keys
  by fetching fresh thumbnails via oEmbed and uploading to storage.

  This is separate from VideoSyncWorker to avoid blocking the main sync process.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 300, states: [:available, :scheduled, :executing]]

  require Logger

  alias SocialObjects.Creators
  alias SocialObjects.Storage
  alias SocialObjects.TiktokShop.OEmbed

  @max_per_run 100

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"brand_id" => brand_id}}) do
    # Skip entirely if storage is not configured to avoid churning through
    # the same videos on every run
    if Storage.configured?() do
      videos = Creators.list_videos_needing_thumbnail_storage(brand_id, @max_per_run)

      if length(videos) > 0 do
        Logger.info("Backfilling #{length(videos)} video thumbnails for brand #{brand_id}")
      end

      Enum.each(videos, fn video ->
        process_video(video)
        Process.sleep(thumbnail_api_delay_ms())
      end)

      :ok
    else
      Logger.debug("Skipping thumbnail backfill - storage not configured")
      :ok
    end
  end

  defp process_video(video) do
    case OEmbed.fetch(video.video_url) do
      {:ok, %{thumbnail_url: url}} when is_binary(url) and url != "" ->
        case Storage.store_video_thumbnail(url, video.id) do
          {:ok, key} ->
            _ = Creators.update_video_thumbnail(video, url, key)
            :ok

          {:error, reason} ->
            # Storage failed but we have a fresh URL - update without storage key
            Logger.debug("Failed to store thumbnail for video #{video.id}: #{inspect(reason)}")
            _ = Creators.update_video_thumbnail(video, url, nil)
            :ok
        end

      {:error, reason} ->
        Logger.debug("Failed to fetch thumbnail for video #{video.id}: #{inspect(reason)}")

      _ ->
        :ok
    end
  end

  defp thumbnail_api_delay_ms do
    Application.get_env(:social_objects, :worker_tuning, [])
    |> Keyword.get(:video_sync, [])
    |> Keyword.get(:thumbnail_api_delay_ms, 100)
  end
end
