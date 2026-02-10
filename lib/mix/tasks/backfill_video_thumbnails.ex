defmodule Mix.Tasks.BackfillVideoThumbnails do
  @moduledoc """
  Backfill thumbnail URLs for existing creator videos.

  Fetches thumbnails from TikTok's oEmbed API for videos that don't have them.

  ## Usage

      # Preview what would be fetched (recommended first step)
      mix backfill_video_thumbnails --dry-run

      # Run the actual backfill
      mix backfill_video_thumbnails

      # Limit to specific brand
      mix backfill_video_thumbnails --brand-id 1

      # Custom batch size (default: 50)
      mix backfill_video_thumbnails --batch-size 100

  ## Options

      --dry-run      Preview without fetching from API
      --brand-id     Only process videos for this brand ID
      --batch-size   Number of videos to process per batch (default: 50)
      --limit        Maximum total videos to process (default: unlimited)
      --delay        Delay in ms between API requests (default: 100)
  """

  use Mix.Task
  require Logger
  import Ecto.Query

  alias Pavoi.Creators
  alias Pavoi.Creators.CreatorVideo
  alias Pavoi.Repo
  alias Pavoi.TiktokShop.OEmbed

  @shortdoc "Backfill thumbnail URLs for creator videos"

  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          dry_run: :boolean,
          brand_id: :integer,
          batch_size: :integer,
          delay: :integer,
          limit: :integer
        ],
        aliases: [d: :dry_run, b: :brand_id, s: :batch_size, l: :limit]
      )

    dry_run = Keyword.get(opts, :dry_run, false)
    brand_id = Keyword.get(opts, :brand_id)
    batch_size = Keyword.get(opts, :batch_size, 50)
    delay = Keyword.get(opts, :delay, 100)
    limit = Keyword.get(opts, :limit)

    Mix.shell().info(
      "Starting video thumbnail backfill#{if dry_run, do: " (DRY RUN)", else: ""}..."
    )

    Mix.shell().info(
      "Batch size: #{batch_size}, Delay: #{delay}ms#{if limit, do: ", Limit: #{limit}", else: ""}"
    )

    if brand_id do
      Mix.shell().info("Filtering to brand_id: #{brand_id}")
    end

    Mix.shell().info("")

    stats = backfill_thumbnails(brand_id, batch_size, delay, limit, dry_run)
    print_summary(stats, dry_run)
  end

  defp backfill_thumbnails(brand_id, batch_size, delay, limit, dry_run) do
    query =
      from(v in CreatorVideo,
        where: is_nil(v.thumbnail_url),
        where: not is_nil(v.video_url),
        order_by: [desc: v.gmv_cents],
        select: v
      )

    query = if brand_id, do: where(query, [v], v.brand_id == ^brand_id), else: query
    query = if limit, do: limit(query, ^limit), else: query

    videos = Repo.all(query)
    total = length(videos)

    Mix.shell().info(
      "Found #{total} videos to process#{if limit, do: " (limited from more)", else: ""}"
    )

    videos
    |> Enum.chunk_every(batch_size)
    |> Enum.with_index(1)
    |> Enum.reduce(%{processed: 0, success: 0, failed: 0, skipped: 0}, fn {batch, batch_num},
                                                                          acc ->
      Mix.shell().info("Processing batch #{batch_num}...")
      process_batch(batch, delay, dry_run, acc)
    end)
  end

  defp process_batch(videos, delay, dry_run, acc) do
    Enum.reduce(videos, acc, fn video, stats ->
      stats = Map.update!(stats, :processed, &(&1 + 1))
      process_video(video, delay, dry_run, stats)
    end)
  end

  defp process_video(video, _delay, true = _dry_run, stats) do
    Mix.shell().info(
      "  [DRY RUN] Would fetch thumbnail for video #{video.id}: #{video.video_url}"
    )

    Map.update!(stats, :skipped, &(&1 + 1))
  end

  defp process_video(video, delay, false = _dry_run, stats) do
    result = fetch_and_update_thumbnail(video)
    Process.sleep(delay)
    update_stats_for_result(result, video, stats)
  end

  defp update_stats_for_result({:ok, _}, _video, stats) do
    Map.update!(stats, :success, &(&1 + 1))
  end

  defp update_stats_for_result({:error, reason}, video, stats) do
    Logger.debug("Failed to fetch thumbnail for #{video.id}: #{inspect(reason)}")
    Map.update!(stats, :failed, &(&1 + 1))
  end

  defp fetch_and_update_thumbnail(video) do
    case OEmbed.fetch(video.video_url) do
      {:ok, %{thumbnail_url: url}} when is_binary(url) and url != "" ->
        Creators.update_video_thumbnail(video, url)

      {:ok, _} ->
        {:error, :no_thumbnail_in_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp print_summary(stats, dry_run) do
    Mix.shell().info("""

    ========================================
    Thumbnail Backfill Complete!
    ========================================

    Processed: #{stats.processed}
    #{if dry_run, do: "Would fetch: #{stats.skipped}", else: "Success: #{stats.success}"}
    #{if dry_run, do: "", else: "Failed: #{stats.failed}"}
    """)
  end
end
