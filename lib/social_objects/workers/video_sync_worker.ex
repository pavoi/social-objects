defmodule SocialObjects.Workers.VideoSyncWorker do
  @moduledoc """
  Oban worker that syncs TikTok Shop video performance data to creator_videos.

  Runs daily via cron. Fetches video performance metrics from the TikTok Shop
  Analytics API and upserts them into the creator_videos table.

  ## Matching Algorithm

  Matches video usernames to creators by:
  1. Current tiktok_username (case-insensitive)
  2. Previous usernames in previous_tiktok_usernames array

  If no match is found, creates a new creator record.

  ## Edge Cases

  - No creator match: Creates new creator with the username
  - API rate limit (429): Snoozes for 5 minutes
  - API server error (5xx): Returns error for Oban retry
  """

  use Oban.Worker,
    queue: :analytics,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing]]

  require Logger

  alias SocialObjects.Catalog
  alias SocialObjects.Creators
  alias SocialObjects.Settings
  alias SocialObjects.TiktokShop.Analytics
  alias SocialObjects.TiktokShop.OEmbed
  alias SocialObjects.TiktokShop.Parsers

  @doc """
  Performs the video sync for a brand.

  Fetches the last 90 days of video performance data and upserts into creator_videos.
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"brand_id" => brand_id}}) do
    # Broadcast sync started
    _ =
      Phoenix.PubSub.broadcast(
        SocialObjects.PubSub,
        "video:sync:#{brand_id}",
        {:video_sync_started}
      )

    case sync_videos(brand_id) do
      {:ok, stats} ->
        _ = Settings.update_videos_last_import_at(brand_id)

        _ =
          Phoenix.PubSub.broadcast(
            SocialObjects.PubSub,
            "video:sync:#{brand_id}",
            {:video_sync_completed, stats}
          )

        Logger.info(
          "Video sync completed for brand #{brand_id}: " <>
            "#{stats.videos_synced} videos, #{stats.creators_created} new creators"
        )

        :ok

      {:snooze, seconds} ->
        {:snooze, seconds}

      {:error, :no_auth_record} ->
        Logger.warning("Video sync skipped for brand #{brand_id}: no TikTok auth record")

        _ =
          Phoenix.PubSub.broadcast(
            SocialObjects.PubSub,
            "video:sync:#{brand_id}",
            {:video_sync_failed, :no_auth_record}
          )

        {:discard, :no_auth_record}

      {:error, reason} ->
        _ =
          Phoenix.PubSub.broadcast(
            SocialObjects.PubSub,
            "video:sync:#{brand_id}",
            {:video_sync_failed, reason}
          )

        {:error, reason}
    end
  end

  defp sync_videos(brand_id) do
    # Fetch last 90 days of video data
    end_date = Date.utc_today() |> Date.add(1) |> Date.to_iso8601()
    start_date = Date.utc_today() |> Date.add(-90) |> Date.to_iso8601()

    case fetch_all_videos(brand_id, start_date, end_date) do
      {:ok, videos} ->
        stats = process_videos(brand_id, videos)
        # Fetch thumbnails for videos missing them (non-blocking, errors are logged)
        fetch_missing_thumbnails(brand_id)
        {:ok, stats}

      {:error, :rate_limited} ->
        Logger.warning("TikTok Analytics API rate limited, snoozing for 5 minutes")
        {:snooze, 300}

      {:error, reason} ->
        Logger.error("Failed to fetch TikTok video analytics: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetch_all_videos(brand_id, start_date, end_date) do
    fetch_all_pages(brand_id, start_date, end_date, nil, [])
  end

  defp fetch_all_pages(brand_id, start_date, end_date, page_token, acc) do
    opts = [
      start_date_ge: start_date,
      end_date_lt: end_date,
      page_size: page_size(),
      sort_field: "gmv",
      sort_order: "DESC",
      account_type: "AFFILIATE_ACCOUNTS"
    ]

    opts = if page_token, do: Keyword.put(opts, :page_token, page_token), else: opts

    Analytics.get_shop_video_performance_list(brand_id, opts)
    |> handle_fetch_page_response(brand_id, start_date, end_date, acc)
  end

  defp handle_fetch_page_response(
         {:ok, %{"data" => data}},
         brand_id,
         start_date,
         end_date,
         acc
       )
       when is_map(data) do
    videos = Map.get(data, "videos", [])
    next_token = Map.get(data, "next_page_token")
    all_videos = acc ++ videos

    if next_token && next_token != "" do
      fetch_all_pages(brand_id, start_date, end_date, next_token, all_videos)
    else
      {:ok, all_videos}
    end
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
    Logger.warning("Unexpected video analytics data payload: #{inspect(data, limit: 80)}")
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
         {:ok, response},
         _brand_id,
         _start_date,
         _end_date,
         _acc
       ) do
    {:error, {:unexpected_response, response}}
  end

  defp handle_fetch_page_response({:error, reason}, _brand_id, _start_date, _end_date, _acc) do
    {:error, reason}
  end

  defp process_videos(brand_id, videos) do
    stats = %{videos_synced: 0, creators_created: 0, creators_matched: 0}

    Enum.reduce(videos, stats, fn video, acc ->
      case process_single_video(brand_id, video) do
        {:ok, :created_creator} ->
          %{
            acc
            | videos_synced: acc.videos_synced + 1,
              creators_created: acc.creators_created + 1
          }

        {:ok, :matched_creator} ->
          %{
            acc
            | videos_synced: acc.videos_synced + 1,
              creators_matched: acc.creators_matched + 1
          }

        {:error, reason} ->
          video_info = "id=#{video["id"] || "nil"}, username=#{video["username"] || "nil"}"
          Logger.warning("Failed to process video (#{video_info}): #{inspect(reason)}")
          acc
      end
    end)
  end

  defp process_single_video(brand_id, video) do
    username = video["username"]
    video_id = video["id"]

    missing_fields =
      []
      |> then(fn acc ->
        if is_nil(username) || username == "", do: [:username | acc], else: acc
      end)
      |> then(fn acc ->
        if is_nil(video_id) || video_id == "", do: [:video_id | acc], else: acc
      end)

    if missing_fields != [] do
      {:error, {:missing_required_fields, missing_fields}}
    else
      process_video_with_creator(brand_id, video, video_id, username)
    end
  end

  defp process_video_with_creator(brand_id, video, video_id, username) do
    case find_or_create_creator(brand_id, username) do
      {nil, _status} ->
        {:error, :creator_not_found}

      {creator, creator_status} ->
        _ = Creators.add_creator_to_brand(creator.id, brand_id)
        upsert_video(brand_id, video_id, creator, video, creator_status)
    end
  end

  defp upsert_video(brand_id, video_id, creator, video, creator_status) do
    video_attrs = build_video_attrs(creator.id, video)

    case Creators.upsert_video_by_tiktok_id(brand_id, video_id, video_attrs) do
      {:ok, upserted_video} ->
        link_video_products(brand_id, upserted_video.id, video["products"])
        {:ok, creator_status}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp find_or_create_creator(brand_id, username) do
    case Creators.get_creator_by_any_username(username) do
      nil -> create_new_creator(brand_id, username)
      creator -> {creator, :matched_creator}
    end
  end

  defp create_new_creator(brand_id, username) do
    case Creators.create_creator(%{tiktok_username: String.downcase(username)}) do
      {:ok, creator} ->
        _ = Creators.add_creator_to_brand(creator.id, brand_id)
        {creator, :created_creator}

      {:error, _changeset} ->
        # Try to fetch again in case of race condition
        handle_creation_race_condition(username)
    end
  end

  defp handle_creation_race_condition(username) do
    case Creators.get_creator_by_any_username(username) do
      nil -> {nil, :created_creator}
      creator -> {creator, :matched_creator}
    end
  end

  defp build_video_attrs(creator_id, video) do
    %{
      creator_id: creator_id,
      title: video["title"],
      video_url: build_video_url(video),
      posted_at: Parsers.parse_video_post_time(video["video_post_time"]),
      gmv_cents: Parsers.parse_gmv_cents(video["gmv"]),
      gpm_cents: Parsers.parse_gmv_cents(video["gpm"]),
      items_sold: Parsers.parse_integer(video["items_sold"]),
      impressions: Parsers.parse_integer(video["views"]),
      ctr: Parsers.parse_percentage(video["click_through_rate"]),
      duration: Parsers.parse_integer(video["duration"]),
      hash_tags: Parsers.parse_hash_tags(video["hash_tags"])
    }
  end

  defp build_video_url(%{"id" => video_id, "username" => username})
       when is_binary(video_id) and is_binary(username) do
    "https://www.tiktok.com/@#{username}/video/#{video_id}"
  end

  defp build_video_url(_), do: nil

  # Links products from API response to the video
  defp link_video_products(_brand_id, _video_id, nil), do: :ok
  defp link_video_products(_brand_id, _video_id, []), do: :ok

  defp link_video_products(brand_id, video_id, products) when is_list(products) do
    Enum.each(products, &link_single_product(brand_id, video_id, &1))
  end

  defp link_single_product(brand_id, video_id, product) do
    tiktok_product_id = product["id"]

    if tiktok_product_id && tiktok_product_id != "" do
      local_product = Catalog.get_product_by_tiktok_product_id(brand_id, tiktok_product_id)
      product_id = if local_product, do: local_product.id, else: nil
      Creators.add_product_to_video(video_id, product_id, tiktok_product_id)
    end
  end

  # Fetches thumbnails for videos that don't have them yet via oEmbed API
  defp fetch_missing_thumbnails(brand_id) do
    videos = Creators.list_videos_without_thumbnails(brand_id)

    thumbnails_fetched =
      Enum.reduce(videos, 0, fn video, count ->
        case OEmbed.fetch(video.video_url) do
          {:ok, %{thumbnail_url: url}} when is_binary(url) and url != "" ->
            _ = Creators.update_video_thumbnail(video, url)
            count + 1

          {:error, reason} ->
            Logger.debug("Failed to fetch thumbnail for video #{video.id}: #{inspect(reason)}")
            count

          _ ->
            count
        end
        |> tap(fn _ ->
          # Rate limit: pause between requests to avoid hitting TikTok limits
          Process.sleep(thumbnail_api_delay_ms())
        end)
      end)

    if thumbnails_fetched > 0 do
      Logger.info("Fetched #{thumbnails_fetched} video thumbnails for brand #{brand_id}")
    end
  end

  defp page_size do
    Application.get_env(:social_objects, :worker_tuning, [])
    |> Keyword.get(:video_sync, [])
    |> Keyword.get(:page_size, 100)
  end

  defp thumbnail_api_delay_ms do
    Application.get_env(:social_objects, :worker_tuning, [])
    |> Keyword.get(:video_sync, [])
    |> Keyword.get(:thumbnail_api_delay_ms, 100)
  end
end
