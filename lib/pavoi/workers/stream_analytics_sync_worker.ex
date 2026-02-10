defmodule Pavoi.Workers.StreamAnalyticsSyncWorker do
  @moduledoc """
  Oban worker that syncs TikTok Shop Analytics API data to streams.

  Runs every 6 hours via cron. Finds streams that ended 2+ days ago and haven't
  been synced yet, then fetches official LIVE performance metrics from the
  TikTok Shop Analytics API.

  ## Matching Algorithm

  Matches API sessions to local streams by:
  1. Username (case-insensitive)
  2. Time window overlap with 5-minute tolerance on each end

  ## Edge Cases

  - No API match found: Logs warning, marks stream synced to prevent retry
  - Multiple API sessions match: Takes session with highest GMV
  - API rate limit (429): Snoozes for 5 minutes
  - API server error (5xx): Returns error for Oban retry
  - GMV discrepancy >20%: Logs warning only
  """

  use Oban.Worker, queue: :analytics, max_attempts: 3

  require Logger

  import Ecto.Query

  alias Pavoi.Repo
  alias Pavoi.TiktokLive.Stream
  alias Pavoi.TiktokShop.Analytics
  alias Pavoi.TiktokShop.Parsers

  @time_tolerance_seconds 5 * 60

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"brand_id" => brand_id}}) do
    streams = find_unsynced_streams(brand_id)

    if Enum.empty?(streams) do
      Logger.debug("No unsynced streams found for brand #{brand_id}")
      :ok
    else
      sync_streams(brand_id, streams)
    end
  end

  defp find_unsynced_streams(brand_id) do
    two_days_ago = DateTime.utc_now() |> DateTime.add(-2, :day)

    from(s in Stream,
      where: s.brand_id == ^brand_id,
      where: s.status == :ended,
      where: s.ended_at <= ^two_days_ago,
      where: is_nil(s.analytics_synced_at),
      order_by: [asc: s.ended_at],
      limit: 50
    )
    |> Repo.all()
  end

  defp sync_streams(brand_id, streams) do
    # Determine date range for API request (covering all unsynced streams)
    {start_date, end_date} = calculate_date_range(streams)

    case fetch_live_sessions(brand_id, start_date, end_date) do
      {:ok, sessions} ->
        match_and_update_streams(brand_id, streams, sessions)

      {:error, :rate_limited} ->
        Logger.warning("TikTok Analytics API rate limited, snoozing for 5 minutes")
        {:snooze, 300}

      {:error, reason} ->
        Logger.error("Failed to fetch TikTok Analytics: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp calculate_date_range(streams) do
    # Get earliest started_at and latest ended_at with some buffer
    earliest = Enum.min_by(streams, & &1.started_at, DateTime) |> Map.get(:started_at)
    latest = Enum.max_by(streams, & &1.ended_at, DateTime) |> Map.get(:ended_at)

    # Add 1 day buffer on each end for timezone differences
    start_date = earliest |> DateTime.add(-1, :day) |> DateTime.to_date() |> Date.to_iso8601()
    end_date = latest |> DateTime.add(2, :day) |> DateTime.to_date() |> Date.to_iso8601()

    {start_date, end_date}
  end

  defp fetch_live_sessions(brand_id, start_date, end_date) do
    fetch_all_pages(brand_id, start_date, end_date, nil, [])
  end

  defp fetch_all_pages(brand_id, start_date, end_date, page_token, acc) do
    opts = [
      start_date_ge: start_date,
      end_date_lt: end_date,
      page_size: 100,
      sort_field: "gmv",
      sort_order: "DESC",
      account_type: "ALL"
    ]

    opts = if page_token, do: Keyword.put(opts, :page_token, page_token), else: opts

    case Analytics.get_shop_live_performance_list(brand_id, opts) do
      {:ok, %{"data" => data}} ->
        # API returns sessions in "live_stream_sessions", not "shop_lives"
        sessions = Map.get(data, "live_stream_sessions", [])
        next_token = Map.get(data, "next_page_token")
        all_sessions = acc ++ sessions

        if next_token && next_token != "" do
          fetch_all_pages(brand_id, start_date, end_date, next_token, all_sessions)
        else
          {:ok, all_sessions}
        end

      {:ok, %{"code" => 429}} ->
        {:error, :rate_limited}

      {:ok, %{"code" => code}} when code >= 500 ->
        {:error, {:server_error, code}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp match_and_update_streams(brand_id, streams, sessions) do
    synced_at = DateTime.utc_now() |> DateTime.truncate(:second)

    Enum.each(streams, fn stream ->
      case find_matching_session(stream, sessions) do
        {:ok, session} ->
          update_stream_with_analytics(brand_id, stream, session, synced_at)

        :no_match ->
          Logger.warning(
            "No TikTok Analytics match found for stream #{stream.id} " <>
              "(#{stream.unique_id}, #{stream.started_at})"
          )

          mark_stream_synced(brand_id, stream.id, synced_at)
      end
    end)

    :ok
  end

  defp find_matching_session(stream, sessions) do
    matching_sessions =
      Enum.filter(sessions, fn session ->
        username_matches?(stream, session) && time_overlaps?(stream, session)
      end)

    case matching_sessions do
      [] ->
        :no_match

      [session] ->
        {:ok, session}

      multiple ->
        # Take session with highest GMV (nested under sales_performance)
        best =
          Enum.max_by(multiple, fn s ->
            Parsers.parse_gmv_amount(get_in(s, ["sales_performance", "gmv"]))
          end)

        {:ok, best}
    end
  end

  defp username_matches?(stream, session) do
    stream_username = String.downcase(stream.unique_id || "")
    api_username = String.downcase(session["username"] || "")
    stream_username == api_username
  end

  defp time_overlaps?(stream, session) do
    # Parse API timestamps (Unix seconds), fallback to now if nil
    now = DateTime.utc_now()
    api_start = Parsers.parse_unix_timestamp(session["start_time"]) || now
    api_end = Parsers.parse_unix_timestamp(session["end_time"]) || now

    stream_start =
      (stream.started_at || now)
      |> DateTime.add(-@time_tolerance_seconds, :second)

    stream_end =
      (stream.ended_at || now)
      |> DateTime.add(@time_tolerance_seconds, :second)

    # Check overlap: stream's window overlaps with API's window
    DateTime.compare(stream_start, api_end) in [:lt, :eq] &&
      DateTime.compare(stream_end, api_start) in [:gt, :eq]
  end

  defp update_stream_with_analytics(brand_id, stream, session, synced_at) do
    # API returns "id" not "live_id", and data is nested under interaction_performance/sales_performance
    live_id = session["id"]
    interaction = session["interaction_performance"] || %{}
    sales = session["sales_performance"] || %{}

    # Fetch per-minute data if live_id is available
    per_minute_data = fetch_per_minute_data(brand_id, live_id)

    attrs = %{
      tiktok_live_id: live_id,
      official_gmv_cents: Parsers.parse_gmv_cents(sales["gmv"]),
      gmv_24h_cents: Parsers.parse_gmv_cents(sales["24h_live_gmv"]),
      avg_view_duration_seconds: Parsers.parse_integer(interaction["avg_viewing_duration"]),
      product_impressions: Parsers.parse_integer(interaction["product_impressions"]),
      product_clicks: Parsers.parse_integer(interaction["product_clicks"]),
      unique_customers: Parsers.parse_integer(sales["customers"]),
      conversion_rate: Parsers.parse_percentage(sales["click_to_order_rate"]),
      analytics_synced_at: synced_at,
      # Additional session-level fields
      total_views: Parsers.parse_integer(interaction["views"]),
      items_sold: Parsers.parse_integer(sales["items_sold"]),
      click_through_rate: Parsers.parse_percentage(interaction["click_through_rate"]),
      # Per-minute time-series data
      analytics_per_minute: per_minute_data
    }

    # Log GMV discrepancy if >20%
    log_gmv_discrepancy(stream, attrs.official_gmv_cents)

    from(s in Stream, where: s.brand_id == ^brand_id and s.id == ^stream.id)
    |> Repo.update_all(set: Enum.to_list(attrs))

    Logger.info(
      "Synced analytics for stream #{stream.id}: " <>
        "official_gmv=$#{(attrs.official_gmv_cents || 0) / 100}, " <>
        "24h_gmv=$#{(attrs.gmv_24h_cents || 0) / 100}" <>
        if(per_minute_data,
          do: ", per_minute_points=#{length(per_minute_data["data"] || [])}",
          else: ""
        )
    )
  end

  defp fetch_per_minute_data(_brand_id, nil), do: nil

  defp fetch_per_minute_data(brand_id, live_id) do
    case fetch_all_per_minute_pages(brand_id, live_id, nil, []) do
      {:ok, minutes_data} when minutes_data != [] ->
        parsed_data = parse_per_minute_data(minutes_data)
        %{"data" => parsed_data}

      {:ok, []} ->
        nil

      {:error, _reason} ->
        # Per-minute API currently returns 500 for all requests (TikTok API issue)
        # Silently fall back to order-based GMV data
        nil
    end
  end

  defp fetch_all_per_minute_pages(brand_id, live_id, page_token, acc) do
    opts = [live_id: live_id, currency: "USD"]
    opts = if page_token, do: Keyword.put(opts, :page_token, page_token), else: opts

    case Analytics.get_shop_live_performance_per_minutes(brand_id, opts) do
      {:ok, %{"data" => data}} ->
        minutes = Map.get(data, "performance_per_minutes", [])
        next_token = Map.get(data, "next_page_token")
        all_minutes = acc ++ minutes

        if next_token && next_token != "" do
          fetch_all_per_minute_pages(brand_id, live_id, next_token, all_minutes)
        else
          {:ok, all_minutes}
        end

      {:ok, %{"code" => code, "message" => message}} ->
        {:error, {:api_error, code, message}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_per_minute_data(minutes_data) do
    Enum.map(minutes_data, fn minute ->
      %{
        "timestamp" => Parsers.parse_integer(minute["timestamp"]),
        "gmv_cents" => Parsers.parse_gmv_cents(minute["gmv"]),
        "viewers" => Parsers.parse_integer(minute["viewers"]),
        "product_clicks" => Parsers.parse_integer(minute["product_clicks"]),
        "orders" => Parsers.parse_integer(minute["orders"])
      }
    end)
  end

  defp mark_stream_synced(brand_id, stream_id, synced_at) do
    from(s in Stream, where: s.brand_id == ^brand_id and s.id == ^stream_id)
    |> Repo.update_all(set: [analytics_synced_at: synced_at])
  end

  defp log_gmv_discrepancy(stream, official_gmv_cents) do
    order_gmv = stream.gmv_cents || 0
    official_gmv = official_gmv_cents || 0

    if order_gmv > 0 && official_gmv > 0 do
      diff_percent = abs(official_gmv - order_gmv) / order_gmv * 100

      if diff_percent > 20 do
        Logger.warning(
          "Stream #{stream.id} GMV discrepancy: " <>
            "order-based=$#{order_gmv / 100}, official=$#{official_gmv / 100} " <>
            "(#{Float.round(diff_percent, 1)}% difference)"
        )
      end
    end
  end
end
