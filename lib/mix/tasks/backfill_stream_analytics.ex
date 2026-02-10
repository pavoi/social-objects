defmodule Mix.Tasks.BackfillStreamAnalytics do
  @moduledoc """
  Backfills TikTok Shop Analytics data for historical streams.

  This task fetches official LIVE performance metrics from the TikTok Shop
  Analytics API and updates streams that haven't been synced yet.

  ## Usage

      # Backfill all unsynced streams for all brands
      mix backfill_stream_analytics

      # Backfill for a specific brand
      mix backfill_stream_analytics --brand-id 1

      # Backfill streams from a specific date range
      mix backfill_stream_analytics --start-date 2026-01-01 --end-date 2026-02-01

      # Dry run (shows what would be synced without making changes)
      mix backfill_stream_analytics --dry-run

      # Limit number of streams to process
      mix backfill_stream_analytics --limit 50

      # Custom batch size and delay (for rate limit management)
      mix backfill_stream_analytics --batch-size 10 --delay-ms 5000

  ## Options

      --brand-id    - Only backfill for this brand ID
      --start-date  - Only backfill streams started on or after this date (YYYY-MM-DD)
      --end-date    - Only backfill streams started before this date (YYYY-MM-DD)
      --dry-run     - Show what would be synced without making changes
      --limit       - Maximum number of streams to process (default: unlimited)
      --batch-size  - Number of streams to process per API call (default: 20)
      --delay-ms    - Milliseconds to wait between batches (default: 2000)
  """

  use Mix.Task

  import Ecto.Query

  alias Pavoi.Repo
  alias Pavoi.TiktokLive.Stream
  alias Pavoi.TiktokShop.Analytics
  alias Pavoi.TiktokShop.Parsers

  @shortdoc "Backfill TikTok Shop Analytics data for historical streams"

  @time_tolerance_seconds 5 * 60

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          brand_id: :integer,
          start_date: :string,
          end_date: :string,
          dry_run: :boolean,
          limit: :integer,
          batch_size: :integer,
          delay_ms: :integer
        ]
      )

    # Start the application
    Mix.Task.run("app.start")

    brand_id = Keyword.get(opts, :brand_id)
    start_date = parse_date(Keyword.get(opts, :start_date))
    end_date = parse_date(Keyword.get(opts, :end_date))
    dry_run = Keyword.get(opts, :dry_run, false)
    limit = Keyword.get(opts, :limit)
    batch_size = Keyword.get(opts, :batch_size, 20)
    delay_ms = Keyword.get(opts, :delay_ms, 2000)

    streams = find_unsynced_streams(brand_id, start_date, end_date, limit)

    if Enum.empty?(streams) do
      Mix.shell().info("No unsynced streams found matching criteria.")
    else
      Mix.shell().info("Found #{length(streams)} unsynced streams")

      if dry_run do
        show_dry_run_summary(streams)
      else
        backfill_streams(streams, batch_size, delay_ms)
      end
    end
  end

  defp parse_date(nil), do: nil

  defp parse_date(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        date

      {:error, _} ->
        Mix.shell().error("Invalid date format: #{date_str}. Use YYYY-MM-DD.")
        System.halt(1)
    end
  end

  defp find_unsynced_streams(brand_id, start_date, end_date, limit) do
    query =
      from(s in Stream,
        where: s.status == :ended,
        where: is_nil(s.analytics_synced_at),
        where: not is_nil(s.ended_at),
        order_by: [desc: s.ended_at],
        preload: [:brand]
      )

    query = if brand_id, do: where(query, [s], s.brand_id == ^brand_id), else: query

    query =
      if start_date do
        start_dt = DateTime.new!(start_date, ~T[00:00:00], "Etc/UTC")
        where(query, [s], s.started_at >= ^start_dt)
      else
        query
      end

    query =
      if end_date do
        end_dt = DateTime.new!(end_date, ~T[00:00:00], "Etc/UTC")
        where(query, [s], s.started_at < ^end_dt)
      else
        query
      end

    query = if limit, do: limit(query, ^limit), else: query

    Repo.all(query)
  end

  defp show_dry_run_summary(streams) do
    Mix.shell().info("\n=== DRY RUN - No changes will be made ===\n")

    streams
    |> Enum.group_by(& &1.brand_id)
    |> Enum.each(fn {brand_id, brand_streams} ->
      brand_name =
        case List.first(brand_streams).brand do
          %{name: name} -> name
          _ -> "Brand #{brand_id}"
        end

      Mix.shell().info("#{brand_name}: #{length(brand_streams)} streams")

      Enum.each(brand_streams, fn stream ->
        date = Calendar.strftime(stream.started_at, "%Y-%m-%d %H:%M")
        Mix.shell().info("  - #{stream.unique_id} (#{date}) - ID: #{stream.id}")
      end)
    end)
  end

  defp backfill_streams(streams, batch_size, delay_ms) do
    # Group by brand_id since API calls are per-brand
    streams_by_brand = Enum.group_by(streams, & &1.brand_id)

    total_brands = map_size(streams_by_brand)
    Mix.shell().info("\nProcessing streams for #{total_brands} brand(s)...\n")

    results =
      streams_by_brand
      |> Enum.with_index(1)
      |> Enum.map(fn {{brand_id, brand_streams}, brand_idx} ->
        brand_name =
          case List.first(brand_streams).brand do
            %{name: name} -> name
            _ -> "Brand #{brand_id}"
          end

        Mix.shell().info(
          "[#{brand_idx}/#{total_brands}] #{brand_name}: #{length(brand_streams)} streams"
        )

        result = process_brand_streams(brand_id, brand_streams, batch_size, delay_ms)

        Mix.shell().info(
          "  Synced: #{result.synced}, No match: #{result.no_match}, Errors: #{result.errors}\n"
        )

        result
      end)

    # Summary
    total_synced = Enum.sum(Enum.map(results, & &1.synced))
    total_no_match = Enum.sum(Enum.map(results, & &1.no_match))
    total_errors = Enum.sum(Enum.map(results, & &1.errors))

    Mix.shell().info("=== Backfill Complete ===")
    Mix.shell().info("Synced: #{total_synced}")
    Mix.shell().info("No match found: #{total_no_match}")
    Mix.shell().info("Errors: #{total_errors}")
  end

  defp process_brand_streams(brand_id, streams, batch_size, delay_ms) do
    # Process in batches
    streams
    |> Enum.chunk_every(batch_size)
    |> Enum.with_index(1)
    |> Enum.reduce(%{synced: 0, no_match: 0, errors: 0}, fn {batch, batch_idx}, acc ->
      total_batches = ceil(length(streams) / batch_size)
      Mix.shell().info("  Batch #{batch_idx}/#{total_batches}...")

      result = process_batch(brand_id, batch)

      # Rate limit delay between batches
      if batch_idx < total_batches do
        Process.sleep(delay_ms)
      end

      %{
        synced: acc.synced + result.synced,
        no_match: acc.no_match + result.no_match,
        errors: acc.errors + result.errors
      }
    end)
  end

  defp process_batch(brand_id, streams) do
    # Calculate date range for this batch
    {start_date, end_date} = calculate_date_range(streams)

    case fetch_live_sessions(brand_id, start_date, end_date) do
      {:ok, sessions} ->
        match_and_update_streams(brand_id, streams, sessions)

      {:error, :rate_limited} ->
        Mix.shell().error("  Rate limited! Waiting 60 seconds...")
        Process.sleep(60_000)
        # Retry once
        case fetch_live_sessions(brand_id, start_date, end_date) do
          {:ok, sessions} -> match_and_update_streams(brand_id, streams, sessions)
          {:error, _} -> %{synced: 0, no_match: 0, errors: length(streams)}
        end

      {:error, reason} ->
        Mix.shell().error("  API error: #{inspect(reason)}")
        %{synced: 0, no_match: 0, errors: length(streams)}
    end
  end

  defp calculate_date_range(streams) do
    earliest = Enum.min_by(streams, & &1.started_at, DateTime) |> Map.get(:started_at)
    latest = Enum.max_by(streams, & &1.ended_at, DateTime) |> Map.get(:ended_at)

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

    Enum.reduce(streams, %{synced: 0, no_match: 0, errors: 0}, fn stream, acc ->
      case find_matching_session(stream, sessions) do
        {:ok, session} ->
          update_stream_with_analytics(brand_id, stream, session, synced_at)
          %{acc | synced: acc.synced + 1}

        :no_match ->
          mark_stream_synced(brand_id, stream.id, synced_at)
          %{acc | no_match: acc.no_match + 1}
      end
    end)
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
    now = DateTime.utc_now()
    api_start = Parsers.parse_unix_timestamp(session["start_time"]) || now
    api_end = Parsers.parse_unix_timestamp(session["end_time"]) || now

    stream_start = DateTime.add(stream.started_at, -@time_tolerance_seconds, :second)

    stream_end =
      DateTime.add(stream.ended_at || now, @time_tolerance_seconds, :second)

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

    from(s in Stream, where: s.brand_id == ^brand_id and s.id == ^stream.id)
    |> Repo.update_all(set: Enum.to_list(attrs))

    if per_minute_data do
      Mix.shell().info("    - Per-minute data: #{length(per_minute_data["data"] || [])} points")
    end
  end

  defp fetch_per_minute_data(_brand_id, nil), do: nil

  defp fetch_per_minute_data(brand_id, live_id) do
    case fetch_all_per_minute_pages(brand_id, live_id, nil, []) do
      {:ok, minutes_data} when minutes_data != [] ->
        parsed_data = parse_per_minute_data(minutes_data)
        %{"data" => parsed_data}

      {:ok, []} ->
        nil

      {:error, reason} ->
        Mix.shell().error("    - Failed to fetch per-minute data: #{inspect(reason)}")
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
end
