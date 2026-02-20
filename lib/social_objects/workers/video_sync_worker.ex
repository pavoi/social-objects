defmodule SocialObjects.Workers.VideoSyncWorker do
  @moduledoc """
  Oban worker that syncs TikTok Shop video performance data.

  Sync behavior:

  - Fetches paginated TikTok video analytics for 90-day and 30-day windows.
  - Dedupes duplicate `video_id` rows within each window deterministically.
  - Upserts canonical all-time metrics onto `creator_videos` with monotonic guards.
  - Persists period snapshots into `creator_video_metric_snapshots`.

  This keeps `/videos` stable for all-time views while enabling period-specific
  metrics/sorting without filtering by `posted_at`.
  """

  use Oban.Worker,
    queue: :analytics,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing]]

  require Logger

  alias SocialObjects.Catalog
  alias SocialObjects.Creators
  alias SocialObjects.Settings
  alias SocialObjects.Storage
  alias SocialObjects.TiktokShop.Analytics
  alias SocialObjects.TiktokShop.OEmbed
  alias SocialObjects.TiktokShop.Parsers
  alias SocialObjects.Workers.ThumbnailBackfillWorker
  alias SocialObjects.Workers.VideoMetricsDeduper

  @snapshot_windows [90, 30]
  @max_page_retry_attempts 3

  @impl Oban.Worker
  def perform(%Oban.Job{id: job_id, args: %{"brand_id" => brand_id} = args}) do
    brand_id = normalize_brand_id(brand_id)
    skip_thumbnails? = Map.get(args, "skip_thumbnails", false)

    _ =
      Phoenix.PubSub.broadcast(
        SocialObjects.PubSub,
        "video:sync:#{brand_id}",
        {:video_sync_started}
      )

    case sync_videos(brand_id,
           source_run_id: "oban-job-#{job_id}",
           skip_thumbnails?: skip_thumbnails?
         ) do
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

  @doc """
  Runs the video sync synchronously.

  Used by backfill tasks/tests where direct return values are needed.
  """
  @spec run_sync(pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:snooze, pos_integer()}
  def run_sync(brand_id, opts \\ []) do
    brand_id = normalize_brand_id(brand_id)

    opts =
      Keyword.put_new_lazy(opts, :source_run_id, fn ->
        "manual-#{System.system_time(:second)}"
      end)

    sync_videos(brand_id, opts)
  end

  defp sync_videos(brand_id, opts) do
    snapshot_date = Keyword.get(opts, :snapshot_date, Date.utc_today())
    source_run_id = Keyword.fetch!(opts, :source_run_id)
    skip_thumbnails? = Keyword.get(opts, :skip_thumbnails?, false)

    with {:ok, window_payloads} <- fetch_window_payloads(brand_id),
         {:ok, video_sync_stats, video_lookup} <-
           upsert_canonical_all_time_videos(brand_id, window_payloads),
         {:ok, snapshot_stats} <-
           persist_window_snapshots(
             brand_id,
             window_payloads,
             video_lookup,
             snapshot_date,
             source_run_id
           ) do
      :ok = maybe_sync_thumbnails(brand_id, skip_thumbnails?)

      dedupe_summary = summarize_dedupe_stats(window_payloads)

      stats =
        Map.merge(video_sync_stats, %{
          snapshot_stats: snapshot_stats,
          duplicate_rows: dedupe_summary.duplicate_rows,
          conflict_video_count: dedupe_summary.conflict_video_count,
          max_conflict_gmv_cents: dedupe_summary.max_conflict_gmv_cents,
          source_run_id: source_run_id,
          snapshot_date: snapshot_date
        })

      _ =
        :telemetry.execute(
          [:social_objects, :video_sync, :write],
          %{
            videos_synced: stats.videos_synced,
            creators_created: stats.creators_created,
            creators_matched: stats.creators_matched,
            snapshot_inserted:
              Enum.reduce(snapshot_stats, 0, fn {_w, s}, acc -> acc + s.inserted end),
            snapshot_updated:
              Enum.reduce(snapshot_stats, 0, fn {_w, s}, acc -> acc + s.updated end),
            snapshot_skipped:
              Enum.reduce(snapshot_stats, 0, fn {_w, s}, acc -> acc + s.skipped end)
          },
          %{brand_id: brand_id, source_run_id: source_run_id}
        )

      {:ok, stats}
    else
      {:error, :rate_limited} ->
        Logger.warning(
          "TikTok Analytics API rate limited for brand #{brand_id}, snoozing 5 minutes"
        )

        {:snooze, 300}

      {:error, reason} ->
        Logger.error(
          "Failed to sync TikTok video analytics for brand #{brand_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp maybe_sync_thumbnails(_brand_id, true), do: :ok

  defp maybe_sync_thumbnails(brand_id, false) do
    fetch_missing_thumbnails(brand_id)

    case enqueue_thumbnail_backfill(brand_id) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to enqueue thumbnail backfill for brand #{brand_id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp fetch_window_payloads(brand_id) do
    Enum.reduce_while(@snapshot_windows, {:ok, %{}}, fn window_days, {:ok, acc} ->
      case fetch_window_payload(brand_id, window_days) do
        {:ok, payload} ->
          {:cont, {:ok, Map.put(acc, window_days, payload)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp fetch_window_payload(brand_id, window_days) do
    end_date = Date.utc_today() |> Date.add(1) |> Date.to_iso8601()
    start_date = Date.utc_today() |> Date.add(-window_days) |> Date.to_iso8601()

    case fetch_all_videos(brand_id, start_date, end_date) do
      {:ok, rows} ->
        dedupe_result = VideoMetricsDeduper.dedupe_rows(rows)

        dedupe_stats =
          dedupe_result.stats
          |> Map.put(:window_days, window_days)

        Logger.info(
          "Video sync dedupe window=#{window_days} brand=#{brand_id} " <>
            "fetched=#{dedupe_stats.total_rows} canonical=#{dedupe_stats.canonical_rows} " <>
            "duplicates=#{dedupe_stats.duplicate_rows} conflicts=#{dedupe_stats.conflict_video_count} " <>
            "max_gmv_discrepancy_cents=#{dedupe_stats.max_gmv_discrepancy_cents}"
        )

        _ =
          :telemetry.execute(
            [:social_objects, :video_sync, :dedupe],
            %{
              fetched_rows: dedupe_stats.total_rows,
              canonical_rows: dedupe_stats.canonical_rows,
              duplicate_rows: dedupe_stats.duplicate_rows,
              conflict_video_count: dedupe_stats.conflict_video_count,
              max_conflict_gmv_cents: dedupe_stats.max_gmv_discrepancy_cents
            },
            %{brand_id: brand_id, window_days: window_days}
          )

        {:ok,
         %{
           window_days: window_days,
           rows: rows,
           canonical_rows: dedupe_result.canonical_rows,
           dedupe_stats: dedupe_stats
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp summarize_dedupe_stats(window_payloads) do
    window_payloads
    |> Map.values()
    |> Enum.map(& &1.dedupe_stats)
    |> Enum.reduce(
      %{duplicate_rows: 0, conflict_video_count: 0, max_conflict_gmv_cents: 0},
      fn stats, acc ->
        %{
          duplicate_rows: acc.duplicate_rows + stats.duplicate_rows,
          conflict_video_count: acc.conflict_video_count + stats.conflict_video_count,
          max_conflict_gmv_cents: max(acc.max_conflict_gmv_cents, stats.max_gmv_discrepancy_cents)
        }
      end
    )
  end

  defp upsert_canonical_all_time_videos(brand_id, window_payloads) do
    merged_rows =
      window_payloads
      |> Map.values()
      |> Enum.flat_map(& &1.canonical_rows)
      |> Enum.map(& &1.raw)

    canonical_all_time_rows = VideoMetricsDeduper.dedupe_rows(merged_rows).canonical_rows

    initial = {%{videos_synced: 0, creators_created: 0, creators_matched: 0}, %{}}

    {stats, video_lookup} =
      Enum.reduce(canonical_all_time_rows, initial, fn candidate, acc ->
        process_canonical_candidate(brand_id, candidate, acc)
      end)

    {:ok, stats, video_lookup}
  end

  defp process_canonical_candidate(brand_id, candidate, {stats_acc, lookup_acc}) do
    case process_single_video(brand_id, candidate) do
      {:ok, creator_status, upserted_video} ->
        updated_stats =
          stats_acc
          |> Map.update!(:videos_synced, &(&1 + 1))
          |> increment_creator_status(creator_status)

        updated_lookup = maybe_track_video_lookup(lookup_acc, candidate.video_id, upserted_video)
        {updated_stats, updated_lookup}

      {:error, reason} ->
        raw = candidate.raw
        video_info = "id=#{raw["id"] || "nil"}, username=#{raw["username"] || "nil"}"
        Logger.warning("Failed to process canonical video (#{video_info}): #{inspect(reason)}")
        {stats_acc, lookup_acc}
    end
  end

  defp maybe_track_video_lookup(lookup_acc, video_id, upserted_video)
       when is_binary(video_id) and video_id != "" do
    Map.put(lookup_acc, video_id, upserted_video)
  end

  defp maybe_track_video_lookup(lookup_acc, _video_id, _upserted_video), do: lookup_acc

  defp increment_creator_status(stats, :created_creator),
    do: Map.update!(stats, :creators_created, &(&1 + 1))

  defp increment_creator_status(stats, :matched_creator),
    do: Map.update!(stats, :creators_matched, &(&1 + 1))

  defp persist_window_snapshots(
         brand_id,
         window_payloads,
         video_lookup,
         snapshot_date,
         source_run_id
       ) do
    window_stats =
      Enum.reduce(@snapshot_windows, %{}, fn window_days, acc ->
        payload = Map.fetch!(window_payloads, window_days)

        stats =
          persist_snapshot_window(
            brand_id,
            window_days,
            payload.canonical_rows,
            video_lookup,
            snapshot_date,
            source_run_id
          )

        Map.put(acc, window_days, stats)
      end)

    {:ok, window_stats}
  end

  defp persist_snapshot_window(
         brand_id,
         window_days,
         canonical_rows,
         video_lookup,
         snapshot_date,
         source_run_id
       ) do
    tiktok_video_ids =
      canonical_rows
      |> Enum.map(& &1.video_id)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    existing_by_video_id =
      Creators.list_video_metric_snapshots_by_keys(
        brand_id,
        snapshot_date,
        window_days,
        tiktok_video_ids
      )

    {rows_to_upsert, counters} =
      Enum.reduce(canonical_rows, {[], %{inserted: 0, updated: 0, skipped: 0}}, fn candidate,
                                                                                   {rows_acc,
                                                                                    counters_acc} ->
        case build_snapshot_row(
               brand_id,
               candidate,
               video_lookup,
               snapshot_date,
               window_days,
               source_run_id
             ) do
          nil ->
            {rows_acc, Map.update!(counters_acc, :skipped, &(&1 + 1))}

          row ->
            apply_snapshot_row_decision(row, existing_by_video_id, rows_acc, counters_acc)
        end
      end)

    rows_to_upsert = Enum.reverse(rows_to_upsert)

    _ = Creators.upsert_video_metric_snapshots(rows_to_upsert)

    Logger.info(
      "Video snapshot sync brand=#{brand_id} window=#{window_days} " <>
        "inserted=#{counters.inserted} updated=#{counters.updated} skipped=#{counters.skipped}"
    )

    _ =
      :telemetry.execute(
        [:social_objects, :video_sync, :snapshots],
        %{
          inserted: counters.inserted,
          updated: counters.updated,
          skipped: counters.skipped
        },
        %{brand_id: brand_id, window_days: window_days, snapshot_date: snapshot_date}
      )

    counters
  end

  defp apply_snapshot_row_decision(row, existing_by_video_id, rows_acc, counters_acc) do
    existing = Map.get(existing_by_video_id, row.tiktok_video_id)

    cond do
      is_nil(existing) ->
        {[row | rows_acc], Map.update!(counters_acc, :inserted, &(&1 + 1))}

      snapshot_row_better?(row, existing) ->
        {[row | rows_acc], Map.update!(counters_acc, :updated, &(&1 + 1))}

      true ->
        {rows_acc, Map.update!(counters_acc, :skipped, &(&1 + 1))}
    end
  end

  defp build_snapshot_row(
         brand_id,
         %{video_id: video_id, metrics: metrics, raw: raw},
         video_lookup,
         snapshot_date,
         window_days,
         source_run_id
       )
       when is_binary(video_id) and video_id != "" do
    creator_video_id =
      case Map.get(video_lookup, video_id) do
        %{id: id} when is_integer(id) ->
          id

        _ ->
          case Creators.get_video_by_tiktok_id(video_id) do
            %{id: id} when is_integer(id) -> id
            _ -> nil
          end
      end

    %{
      brand_id: brand_id,
      creator_video_id: creator_video_id,
      tiktok_video_id: video_id,
      snapshot_date: snapshot_date,
      window_days: window_days,
      gmv_cents: metrics.gmv_cents || 0,
      views: metrics.views || 0,
      items_sold: metrics.items_sold || 0,
      gpm_cents: metrics.gpm_cents,
      ctr: metrics.ctr,
      source_run_id: source_run_id,
      raw_payload: raw
    }
  end

  defp build_snapshot_row(
         _brand_id,
         _candidate,
         _video_lookup,
         _snapshot_date,
         _window_days,
         _source_run_id
       ),
       do: nil

  defp snapshot_row_better?(incoming, existing) do
    incoming_quality = %{
      gmv_cents: incoming.gmv_cents,
      views: incoming.views,
      items_sold: incoming.items_sold,
      gpm_cents: incoming.gpm_cents,
      ctr: incoming.ctr
    }

    existing_quality = %{
      gmv_cents: existing.gmv_cents,
      views: existing.views,
      items_sold: existing.items_sold,
      gpm_cents: existing.gpm_cents,
      ctr: existing.ctr
    }

    case VideoMetricsDeduper.compare_metric_quality(incoming_quality, existing_quality) do
      :gt -> true
      :lt -> false
      :eq -> is_nil(existing.creator_video_id) and not is_nil(incoming.creator_video_id)
    end
  end

  defp fetch_all_videos(brand_id, start_date, end_date) do
    fetch_all_pages(brand_id, start_date, end_date, nil, [], 0)
  end

  defp fetch_all_pages(brand_id, start_date, end_date, page_token, acc, page_index) do
    opts = [
      start_date_ge: start_date,
      end_date_lt: end_date,
      page_size: page_size(),
      sort_field: "gmv",
      sort_order: "DESC",
      account_type: "AFFILIATE_ACCOUNTS"
    ]

    opts = if page_token, do: Keyword.put(opts, :page_token, page_token), else: opts

    response = fetch_page_with_retry(brand_id, opts, 1)
    handle_fetch_all_pages_response(response, brand_id, start_date, end_date, acc, page_index)
  end

  defp handle_fetch_all_pages_response(
         {:ok, %{"data" => data}},
         brand_id,
         start_date,
         end_date,
         acc,
         page_index
       )
       when is_map(data) do
    videos = Map.get(data, "videos", [])
    next_token = Map.get(data, "next_page_token")
    all_videos = acc ++ videos

    if next_token && next_token != "" do
      fetch_all_pages(brand_id, start_date, end_date, next_token, all_videos, page_index + 1)
    else
      {:ok, all_videos}
    end
  end

  defp handle_fetch_all_pages_response(
         {:ok, %{"data" => nil}},
         _brand_id,
         _start_date,
         _end_date,
         acc,
         _page_index
       ) do
    {:ok, acc}
  end

  defp handle_fetch_all_pages_response(
         {:ok, %{"code" => 429}},
         _brand_id,
         _start_date,
         _end_date,
         _acc,
         _page_index
       ) do
    {:error, :rate_limited}
  end

  defp handle_fetch_all_pages_response(
         {:ok, %{"code" => code}},
         _brand_id,
         _start_date,
         _end_date,
         _acc,
         _page_index
       )
       when code >= 500 do
    {:error, {:server_error, code}}
  end

  defp handle_fetch_all_pages_response(
         {:ok, response},
         brand_id,
         _start_date,
         _end_date,
         _acc,
         page_index
       ) do
    Logger.warning(
      "Unexpected video analytics response for brand #{brand_id} page=#{page_index}: " <>
        inspect(response, limit: 80)
    )

    {:error, {:unexpected_response, response}}
  end

  defp handle_fetch_all_pages_response(
         {:error, reason},
         _brand_id,
         _start_date,
         _end_date,
         _acc,
         _page_index
       ) do
    {:error, reason}
  end

  defp fetch_page_with_retry(_brand_id, _opts, attempt) when attempt > @max_page_retry_attempts do
    {:error, :max_page_retries_exceeded}
  end

  defp fetch_page_with_retry(brand_id, opts, attempt) do
    case fetch_video_page(brand_id, opts) do
      {:error, {:rate_limited, _body}} ->
        {:error, :rate_limited}

      {:ok, %{"code" => 429}} ->
        {:error, :rate_limited}

      {:ok, %{"code" => code}} = response when code >= 500 ->
        maybe_retry_page(brand_id, opts, attempt, {:server_error, code}, response)

      {:error, reason} = error ->
        if retryable_fetch_error?(reason) do
          maybe_retry_page(brand_id, opts, attempt, reason, error)
        else
          error
        end

      response ->
        response
    end
  end

  defp maybe_retry_page(brand_id, opts, attempt, reason, fallback) do
    if attempt < @max_page_retry_attempts do
      delay_ms = retry_delay_ms(attempt)

      Logger.warning(
        "Retrying video analytics page fetch for brand #{brand_id} in #{delay_ms}ms " <>
          "attempt=#{attempt} reason=#{inspect(reason)}"
      )

      Process.sleep(delay_ms)
      fetch_page_with_retry(brand_id, opts, attempt + 1)
    else
      fallback
    end
  end

  defp fetch_video_page(brand_id, opts) do
    case Application.get_env(:social_objects, :video_sync_page_fetcher) do
      fun when is_function(fun, 2) -> fun.(brand_id, opts)
      _ -> Analytics.get_shop_video_performance_list(brand_id, opts)
    end
  end

  defp retryable_fetch_error?(reason)
       when reason in [:timeout, :closed, :econnrefused, :nxdomain, :einval],
       do: true

  defp retryable_fetch_error?({:http_error, status}) when status >= 500, do: true
  defp retryable_fetch_error?({:transport_error, _}), do: true
  defp retryable_fetch_error?({:req, _}), do: true
  defp retryable_fetch_error?(_), do: false

  defp retry_delay_ms(attempt) do
    base =
      Application.get_env(:social_objects, :worker_tuning, [])
      |> Keyword.get(:video_sync, [])
      |> Keyword.get(:page_retry_base_delay_ms, 500)

    trunc(base * :math.pow(2, attempt - 1))
  end

  defp process_single_video(brand_id, candidate) do
    video = candidate.raw
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
      process_video_with_creator(brand_id, candidate, video_id, username)
    end
  end

  defp process_video_with_creator(brand_id, candidate, video_id, username) do
    case find_or_create_creator(brand_id, username) do
      {nil, _status} ->
        {:error, :creator_not_found}

      {creator, creator_status} ->
        _ = Creators.add_creator_to_brand(creator.id, brand_id)
        upsert_video(brand_id, video_id, creator, candidate, creator_status)
    end
  end

  defp upsert_video(brand_id, video_id, creator, candidate, creator_status) do
    video_attrs = build_video_attrs(creator.id, candidate)

    case Creators.upsert_video_by_tiktok_id(brand_id, video_id, video_attrs) do
      {:ok, upserted_video} ->
        link_video_products(brand_id, upserted_video.id, candidate.raw["products"])
        {:ok, creator_status, upserted_video}

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
        handle_creation_race_condition(username)
    end
  end

  defp handle_creation_race_condition(username) do
    case Creators.get_creator_by_any_username(username) do
      nil -> {nil, :created_creator}
      creator -> {creator, :matched_creator}
    end
  end

  defp build_video_attrs(creator_id, candidate) do
    video = candidate.raw
    metrics = candidate.metrics

    %{
      creator_id: creator_id,
      title: video["title"],
      video_url: build_video_url(video),
      posted_at: metrics.posted_at,
      gmv_cents: metrics.gmv_cents,
      gpm_cents: metrics.gpm_cents,
      items_sold: metrics.items_sold,
      impressions: metrics.views,
      ctr: metrics.ctr,
      duration: metrics.duration,
      hash_tags: metrics.hash_tags,
      affiliate_orders: Parsers.parse_integer(video["affiliate_orders"], default: 0),
      likes: Parsers.parse_integer(video["likes"], default: 0),
      comments: Parsers.parse_integer(video["comments"], default: 0),
      shares: Parsers.parse_integer(video["shares"], default: 0)
    }
  end

  defp build_video_url(%{"id" => video_id, "username" => username})
       when is_binary(video_id) and is_binary(username) do
    "https://www.tiktok.com/@#{username}/video/#{video_id}"
  end

  defp build_video_url(_), do: nil

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

  defp fetch_missing_thumbnails(brand_id) do
    videos = Creators.list_videos_without_thumbnails(brand_id)

    thumbnails_fetched =
      Enum.reduce(videos, 0, fn video, count ->
        updated_count =
          case OEmbed.fetch(video.video_url) do
            {:ok, %{thumbnail_url: url}} when is_binary(url) and url != "" ->
              store_and_update_thumbnail(video, url)
              count + 1

            {:error, reason} ->
              Logger.debug("Failed to fetch thumbnail for video #{video.id}: #{inspect(reason)}")
              count

            _ ->
              count
          end

        Process.sleep(thumbnail_api_delay_ms())
        updated_count
      end)

    if thumbnails_fetched > 0 do
      Logger.info("Fetched #{thumbnails_fetched} video thumbnails for brand #{brand_id}")
    end
  end

  defp store_and_update_thumbnail(video, url) do
    _ =
      case Storage.store_video_thumbnail(url, video.id) do
        {:ok, key} -> Creators.update_video_thumbnail(video, url, key)
        _ -> Creators.update_video_thumbnail(video, url, nil)
      end

    :ok
  end

  defp enqueue_thumbnail_backfill(brand_id) do
    ThumbnailBackfillWorker.new(%{"brand_id" => brand_id})
    |> Oban.insert()
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

  defp normalize_brand_id(brand_id) when is_integer(brand_id), do: brand_id

  defp normalize_brand_id(brand_id) when is_binary(brand_id) do
    String.to_integer(brand_id)
  end
end
