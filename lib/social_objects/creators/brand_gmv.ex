defmodule SocialObjects.Creators.BrandGmv do
  @moduledoc """
  Context module for brand-specific GMV operations.

  Handles syncing GMV data from TikTok video/live analytics to brand_creators,
  calculating cumulative deltas, and managing creator matching/creation.

  ## Data Sources

  Uses TikTok Shop Analytics API endpoints:
  - `shop_videos/performance` - Video-based GMV (30-day rolling window)
  - `shop_lives/performance` - Live-based GMV (30-day rolling window)

  These APIs return per-username aggregates, which we match to creators and
  store on the BrandCreator junction table.

  ## Cumulative Tracking

  Uses delta-accumulation pattern:
  1. Store current rolling 30-day values
  2. Calculate delta = new_rolling - previous_rolling (max 0)
  3. Add delta to cumulative totals
  4. Record delta in CreatorPerformanceSnapshot for audit trail
  """

  import Ecto.Query
  require Logger

  alias SocialObjects.Creators
  alias SocialObjects.Creators.BrandCreator
  alias SocialObjects.Creators.CreatorPerformanceSnapshot
  alias SocialObjects.Repo
  alias SocialObjects.TiktokShop.Analytics
  alias SocialObjects.TiktokShop.Parsers

  @rolling_window_days 30

  @doc """
  Main entry point: syncs brand-specific GMV from video/live analytics.

  Fetches 30-day rolling performance data from TikTok Shop Analytics,
  groups by username, and updates BrandCreator records.

  Returns `{:ok, stats}` or `{:error, reason}`.
  """
  def sync_from_analytics(brand_id) do
    Logger.info("[BrandGmv] Starting sync for brand #{brand_id}")

    with {:ok, video_data} <- fetch_all_video_performance(brand_id),
         {:ok, live_data} <- fetch_all_live_performance(brand_id) do
      stats = process_analytics_data(brand_id, video_data, live_data)
      Logger.info("[BrandGmv] Completed sync for brand #{brand_id}: #{inspect(stats)}")
      {:ok, stats}
    end
  end

  @doc """
  Fetches all video performance data with pagination.
  """
  def fetch_all_video_performance(brand_id) do
    end_date = Date.utc_today() |> Date.add(1) |> Date.to_iso8601()
    start_date = Date.utc_today() |> Date.add(-@rolling_window_days) |> Date.to_iso8601()

    fetch_all_pages(:video, brand_id, start_date, end_date, nil, [])
  end

  @doc """
  Fetches all live performance data with pagination.
  """
  def fetch_all_live_performance(brand_id) do
    end_date = Date.utc_today() |> Date.add(1) |> Date.to_iso8601()
    start_date = Date.utc_today() |> Date.add(-@rolling_window_days) |> Date.to_iso8601()

    fetch_all_pages(:live, brand_id, start_date, end_date, nil, [])
  end

  defp fetch_all_pages(type, brand_id, start_date, end_date, page_token, acc) do
    opts = [
      start_date_ge: start_date,
      end_date_lt: end_date,
      page_size: 100,
      sort_field: "gmv",
      sort_order: "DESC",
      account_type: "AFFILIATE_ACCOUNTS"
    ]

    opts = if page_token, do: Keyword.put(opts, :page_token, page_token), else: opts

    result =
      case type do
        :video -> Analytics.get_shop_video_performance_list(brand_id, opts)
        :live -> Analytics.get_shop_live_performance_list(brand_id, opts)
      end

    handle_page_response(type, result, brand_id, start_date, end_date, acc)
  end

  defp handle_page_response(type, {:ok, %{"data" => data}}, brand_id, start_date, end_date, acc)
       when is_map(data) do
    items_key = if type == :video, do: "videos", else: "live_stream_sessions"
    items = Map.get(data, items_key, [])
    next_token = Map.get(data, "next_page_token")
    all_items = acc ++ items

    if next_token && next_token != "" do
      # Rate limiting
      Process.sleep(300)
      fetch_all_pages(type, brand_id, start_date, end_date, next_token, all_items)
    else
      {:ok, all_items}
    end
  end

  defp handle_page_response(
         _type,
         {:ok, %{"data" => nil}},
         _brand_id,
         _start_date,
         _end_date,
         acc
       ) do
    {:ok, acc}
  end

  defp handle_page_response(
         _type,
         {:ok, %{"code" => 429}},
         _brand_id,
         _start_date,
         _end_date,
         _acc
       ) do
    {:error, :rate_limited}
  end

  defp handle_page_response(
         _type,
         {:ok, %{"code" => code}},
         _brand_id,
         _start_date,
         _end_date,
         _acc
       )
       when code >= 500 do
    {:error, {:server_error, code}}
  end

  defp handle_page_response(_type, {:error, reason}, _brand_id, _start_date, _end_date, _acc) do
    {:error, reason}
  end

  defp handle_page_response(_type, result, _brand_id, _start_date, _end_date, acc) do
    Logger.warning("[BrandGmv] Unexpected API response: #{inspect(result, limit: 200)}")
    {:ok, acc}
  end

  @doc """
  Processes video and live analytics data, updating BrandCreator records.
  """
  def process_analytics_data(brand_id, video_data, live_data) do
    # Group video GMV by username
    video_by_username =
      video_data
      |> Enum.group_by(&normalize_username(&1["username"]))
      |> Enum.map(fn {username, videos} ->
        total_gmv = videos |> Enum.map(&parse_gmv(&1["gmv"])) |> Enum.sum()
        {username, total_gmv}
      end)
      |> Map.new()

    # Group live GMV by username
    live_by_username =
      live_data
      |> Enum.group_by(&normalize_username(&1["username"]))
      |> Enum.map(fn {username, lives} ->
        total_gmv = lives |> Enum.map(&parse_gmv(&1["gmv"])) |> Enum.sum()
        {username, total_gmv}
      end)
      |> Map.new()

    # Get all unique usernames
    all_usernames =
      (Map.keys(video_by_username) ++ Map.keys(live_by_username))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    stats = %{
      usernames_processed: 0,
      creators_matched: 0,
      creators_created: 0,
      brand_creators_updated: 0,
      errors: 0
    }

    today = Date.utc_today()
    now = DateTime.utc_now()

    Enum.reduce(all_usernames, stats, fn username, acc ->
      video_gmv = Map.get(video_by_username, username, 0)
      live_gmv = Map.get(live_by_username, username, 0)
      total_gmv = video_gmv + live_gmv

      case match_or_create_creator(brand_id, username) do
        {:ok, creator, :matched} ->
          update_brand_creator_gmv(
            brand_id,
            creator.id,
            video_gmv,
            live_gmv,
            total_gmv,
            today,
            now
          )

          %{
            acc
            | usernames_processed: acc.usernames_processed + 1,
              creators_matched: acc.creators_matched + 1,
              brand_creators_updated: acc.brand_creators_updated + 1
          }

        {:ok, creator, :created} ->
          update_brand_creator_gmv(
            brand_id,
            creator.id,
            video_gmv,
            live_gmv,
            total_gmv,
            today,
            now
          )

          %{
            acc
            | usernames_processed: acc.usernames_processed + 1,
              creators_created: acc.creators_created + 1,
              brand_creators_updated: acc.brand_creators_updated + 1
          }

        {:error, reason} ->
          Logger.warning("[BrandGmv] Failed to process username #{username}: #{inspect(reason)}")
          %{acc | usernames_processed: acc.usernames_processed + 1, errors: acc.errors + 1}
      end
    end)
  end

  defp normalize_username(nil), do: nil
  defp normalize_username(""), do: nil
  defp normalize_username(username), do: String.downcase(String.trim(username))

  defp parse_gmv(nil), do: 0

  defp parse_gmv(gmv) do
    Parsers.parse_gmv_cents(gmv, default: 0) || 0
  end

  @doc """
  Matches a username to an existing creator or creates a new one.

  Matching priority:
  1. Current tiktok_username (case-insensitive)
  2. Previous usernames in previous_tiktok_usernames array

  If no match, creates a new creator with enrichment_source = "brand_gmv_sync".

  Returns `{:ok, creator, :matched}`, `{:ok, creator, :created}`, or `{:error, reason}`.
  """
  def match_or_create_creator(brand_id, username) do
    case Creators.get_creator_by_any_username(username) do
      nil ->
        create_creator_from_username(brand_id, username)

      creator ->
        # Ensure creator is associated with this brand
        _ = Creators.add_creator_to_brand(creator.id, brand_id)
        {:ok, creator, :matched}
    end
  end

  defp create_creator_from_username(brand_id, username) do
    attrs = %{
      tiktok_username: String.downcase(username),
      enrichment_source: "brand_gmv_sync"
    }

    case Creators.create_creator(attrs) do
      {:ok, creator} ->
        _ = Creators.add_creator_to_brand(creator.id, brand_id)
        {:ok, creator, :created}

      {:error, changeset} ->
        # Handle race condition - creator might have been created by another process
        case Creators.get_creator_by_any_username(username) do
          nil -> {:error, changeset}
          creator -> {:ok, creator, :matched}
        end
    end
  end

  @doc """
  Updates BrandCreator GMV fields with delta accumulation.

  1. Gets current BrandCreator record (or creates if not exists)
  2. Calculates delta = max(0, new_gmv - previous_gmv)
  3. Adds delta to cumulative totals (skipped if gmv_seeded_externally is true)
  4. Creates CreatorPerformanceSnapshot for audit trail

  ## Bootstrap Guard

  If `gmv_seeded_externally` is true (set during Euka import), the first TikTok sync
  will skip adding deltas to cumulative values to prevent double-counting. The flag
  is reset to false after the first sync.
  """
  def update_brand_creator_gmv(brand_id, creator_id, video_gmv, live_gmv, total_gmv, date, now) do
    Repo.transaction(fn ->
      # Get or create brand_creator
      brand_creator = get_or_create_brand_creator(brand_id, creator_id)

      # Calculate deltas
      {video_delta, live_delta, total_delta} =
        calculate_deltas(brand_creator, video_gmv, live_gmv, total_gmv)

      # Check bootstrap flag - if externally seeded, skip delta accumulation this run
      {effective_video_delta, effective_live_delta, effective_total_delta, reset_flag} =
        if brand_creator.gmv_seeded_externally do
          # First sync after external seed: apply zero delta, reset flag
          {0, 0, 0, true}
        else
          {video_delta, live_delta, total_delta, false}
        end

      # Update tracking start date if this is first sync
      tracking_started_at =
        brand_creator.brand_gmv_tracking_started_at || date

      # Build update set, conditionally resetting the bootstrap flag
      update_set = [
        brand_gmv_cents: total_gmv,
        brand_video_gmv_cents: video_gmv,
        brand_live_gmv_cents: live_gmv,
        cumulative_brand_gmv_cents:
          (brand_creator.cumulative_brand_gmv_cents || 0) + effective_total_delta,
        cumulative_brand_video_gmv_cents:
          (brand_creator.cumulative_brand_video_gmv_cents || 0) + effective_video_delta,
        cumulative_brand_live_gmv_cents:
          (brand_creator.cumulative_brand_live_gmv_cents || 0) + effective_live_delta,
        brand_gmv_tracking_started_at: tracking_started_at,
        brand_gmv_last_synced_at: now,
        updated_at: now
      ]

      # Reset bootstrap flag if it was set
      update_set =
        if reset_flag do
          Keyword.put(update_set, :gmv_seeded_externally, false)
        else
          update_set
        end

      # Update brand_creator with new values
      from(bc in BrandCreator, where: bc.id == ^brand_creator.id)
      |> Repo.update_all(set: update_set)

      # Create performance snapshot for audit trail (use effective deltas)
      create_gmv_snapshot(brand_id, creator_id, date, %{
        video_gmv: video_gmv,
        live_gmv: live_gmv,
        total_gmv: total_gmv,
        video_delta: effective_video_delta,
        live_delta: effective_live_delta,
        total_delta: effective_total_delta
      })

      :ok
    end)
  end

  defp get_or_create_brand_creator(brand_id, creator_id) do
    case Repo.get_by(BrandCreator, brand_id: brand_id, creator_id: creator_id) do
      nil ->
        # Create the association
        {:ok, _} = Creators.add_creator_to_brand(creator_id, brand_id)
        Repo.get_by!(BrandCreator, brand_id: brand_id, creator_id: creator_id)

      brand_creator ->
        brand_creator
    end
  end

  @doc """
  Calculates GMV deltas using the delta-accumulation pattern.

  Delta = max(0, new_value - previous_value)

  We use max(0, ...) because TikTok's rolling window can cause the value
  to decrease (when old orders drop off), but we don't want to subtract
  from cumulative totals.
  """
  def calculate_deltas(brand_creator, new_video_gmv, new_live_gmv, new_total_gmv) do
    prev_video = brand_creator.brand_video_gmv_cents || 0
    prev_live = brand_creator.brand_live_gmv_cents || 0
    prev_total = brand_creator.brand_gmv_cents || 0

    video_delta = max(0, new_video_gmv - prev_video)
    live_delta = max(0, new_live_gmv - prev_live)
    total_delta = max(0, new_total_gmv - prev_total)

    {video_delta, live_delta, total_delta}
  end

  defp create_gmv_snapshot(brand_id, creator_id, date, gmv_data) do
    attrs = %{
      creator_id: creator_id,
      snapshot_date: date,
      source: "brand_gmv",
      gmv_cents: gmv_data.total_gmv,
      video_gmv_cents: gmv_data.video_gmv,
      live_gmv_cents: gmv_data.live_gmv,
      gmv_delta_cents: gmv_data.total_delta,
      video_gmv_delta_cents: gmv_data.video_delta,
      live_gmv_delta_cents: gmv_data.live_delta
    }

    # Upsert to handle re-runs on same day
    %CreatorPerformanceSnapshot{brand_id: brand_id}
    |> CreatorPerformanceSnapshot.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :gmv_cents,
           :video_gmv_cents,
           :live_gmv_cents,
           :gmv_delta_cents,
           :video_gmv_delta_cents,
           :live_gmv_delta_cents,
           :updated_at
         ]},
      conflict_target: [:creator_id, :snapshot_date, :source]
    )
  end

  @doc """
  Batch loads brand GMV data for UI display.

  Returns a map of creator_id => %{
    brand_gmv_cents: integer,
    cumulative_brand_gmv_cents: integer,
    brand_gmv_tracking_started_at: Date | nil
  }
  """
  def batch_load_brand_gmv(brand_id, creator_ids) when is_list(creator_ids) do
    if creator_ids == [] do
      %{}
    else
      from(bc in BrandCreator,
        where: bc.brand_id == ^brand_id and bc.creator_id in ^creator_ids,
        select:
          {bc.creator_id,
           %{
             brand_gmv_cents: bc.brand_gmv_cents,
             brand_video_gmv_cents: bc.brand_video_gmv_cents,
             brand_live_gmv_cents: bc.brand_live_gmv_cents,
             cumulative_brand_gmv_cents: bc.cumulative_brand_gmv_cents,
             cumulative_brand_video_gmv_cents: bc.cumulative_brand_video_gmv_cents,
             cumulative_brand_live_gmv_cents: bc.cumulative_brand_live_gmv_cents,
             brand_gmv_tracking_started_at: bc.brand_gmv_tracking_started_at
           }}
      )
      |> Repo.all()
      |> Map.new()
    end
  end

  @doc """
  Gets a single brand_creator record with brand GMV data.
  """
  def get_brand_creator(brand_id, creator_id) do
    Repo.get_by(BrandCreator, brand_id: brand_id, creator_id: creator_id)
  end
end
