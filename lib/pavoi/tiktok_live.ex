defmodule Pavoi.TiktokLive do
  @moduledoc """
  Context module for TikTok Live stream data capture.

  This module provides the public API for:
  - Querying captured live streams and their data
  - Manual stream capture control
  - Statistics and analytics

  ## Architecture

  The TikTok Live capture system consists of:

  1. **TiktokLiveMonitorWorker** - Polls TikTok every 2 minutes to detect live status
  2. **TiktokLiveStreamWorker** - Manages capture for a single stream
  3. **Connection** - WebSocket connection to TikTok's WebCast service
  4. **EventHandler** - Persists events and maintains statistics

  ## Configuration

  Required configuration in `config.exs`:

      config :pavoi, :tiktok_bridge_url, System.get_env("TIKTOK_BRIDGE_URL")

      config :pavoi, :tiktok_live_monitor,
        accounts: ["pavoi"]

  """

  import Ecto.Query, warn: false

  require Logger

  alias Pavoi.Repo
  alias Pavoi.Sessions.SessionProduct
  alias Pavoi.TiktokLive.{Client, Comment, SessionStream, Stream, StreamStat}
  alias Pavoi.Workers.{TiktokLiveMonitorWorker, TiktokLiveStreamWorker}

  ## Streams

  @doc """
  Returns a list of all captured streams, most recent first.
  """
  def list_streams do
    Stream
    |> order_by([s], desc: s.started_at)
    |> Repo.all()
  end

  @doc """
  Returns a list of streams with optional filtering.

  ## Options

  - `:status` - Filter by status (:capturing, :ended, :failed)
  - `:unique_id` - Filter by TikTok username
  - `:sort_by` - Field to sort by ("started", "viewers", "gmv", "comments", "duration")
  - `:sort_dir` - Direction ("asc" or "desc", default "desc")
  - `:limit` - Limit number of results
  - `:offset` - Offset for pagination
  """
  def list_streams(opts) do
    Stream
    |> apply_filters(opts)
    |> apply_sorting(opts)
    |> Repo.all()
  end

  @doc """
  Counts streams with optional filtering.

  Same filters as `list_streams/1` except `:limit` and `:offset` are ignored.
  """
  def count_streams(opts \\ []) do
    # Remove pagination options for count query
    count_opts = Keyword.drop(opts, [:limit, :offset])

    Stream
    |> apply_filters(count_opts)
    |> Repo.aggregate(:count)
  end

  @doc """
  Gets a single stream by ID.

  Returns `nil` if not found.
  """
  def get_stream(id) do
    Repo.get(Stream, id)
  end

  @doc """
  Gets a single stream by ID.

  Raises `Ecto.NoResultsError` if not found.
  """
  def get_stream!(id) do
    Repo.get!(Stream, id)
  end

  @doc """
  Gets the currently active (capturing) stream, if any.
  """
  def get_active_stream do
    from(s in Stream,
      where: s.status == :capturing,
      order_by: [desc: s.started_at],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Gets the most recent stream for a given account.
  """
  def get_latest_stream(unique_id) do
    from(s in Stream,
      where: s.unique_id == ^unique_id,
      order_by: [desc: s.started_at],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Marks a stream as ended if it hasn't been ended already.

  Returns `{:ok, :ended}` when the update was applied, or `{:error, :already_ended}`.
  """
  def mark_stream_ended(stream_id) do
    ended_at = DateTime.utc_now() |> DateTime.truncate(:second)

    {updated, _} =
      from(s in Stream,
        where: s.id == ^stream_id and s.status != :ended
      )
      |> Repo.update_all(set: [status: :ended, ended_at: ended_at])

    if updated == 1 do
      {:ok, :ended}
    else
      {:error, :already_ended}
    end
  end

  @doc """
  Marks a stream's report as sent. Returns {:ok, :marked} or {:error, :already_sent}.

  Uses an atomic update to ensure only one report is ever sent per stream.
  """
  def mark_report_sent(stream_id) do
    sent_at = DateTime.utc_now() |> DateTime.truncate(:second)

    {updated, _} =
      from(s in Stream,
        where: s.id == ^stream_id and is_nil(s.report_sent_at)
      )
      |> Repo.update_all(set: [report_sent_at: sent_at])

    if updated == 1 do
      {:ok, :marked}
    else
      {:error, :already_sent}
    end
  end

  @doc """
  Updates a stream's GMV data.

  `gmv_data` should be a map with `:total_gmv_cents`, `:total_orders`, and `:hourly` keys.
  The `:hourly` key should contain a list of maps with `:hour`, `:gmv_cents`, and `:order_count`.
  """
  def update_stream_gmv(stream_id, gmv_data) do
    stream = get_stream!(stream_id)

    # Convert hourly data to serializable format (DateTime keys to ISO strings)
    hourly_map = serialize_hourly_gmv(gmv_data.hourly)

    stream
    |> Stream.changeset(%{
      gmv_cents: gmv_data.total_gmv_cents,
      gmv_order_count: gmv_data.total_orders,
      gmv_hourly: hourly_map
    })
    |> Repo.update()
  end

  defp serialize_hourly_gmv(hourly) when is_list(hourly) do
    %{
      "data" =>
        Enum.map(hourly, fn h ->
          %{
            "hour" => DateTime.to_iso8601(h.hour),
            "gmv_cents" => h.gmv_cents,
            "order_count" => h.order_count
          }
        end)
    }
  end

  defp serialize_hourly_gmv(_), do: nil

  ## Comments

  @doc """
  Returns comments for a stream with pagination.

  ## Options

  - `:page` - Page number (default: 1)
  - `:per_page` - Comments per page (default: 50)
  - `:order` - :asc or :desc (default: :desc)
  """
  def list_stream_comments(stream_id, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)
    order = Keyword.get(opts, :order, :desc)

    query =
      from(c in Comment,
        where: c.stream_id == ^stream_id,
        limit: ^per_page,
        offset: ^((page - 1) * per_page)
      )

    query =
      case order do
        :asc -> order_by(query, [c], asc: c.commented_at)
        :desc -> order_by(query, [c], desc: c.commented_at)
      end

    comments = Repo.all(query)
    total = count_stream_comments(stream_id)

    %{
      comments: comments,
      page: page,
      per_page: per_page,
      total: total,
      has_more: total > page * per_page
    }
  end

  @doc """
  Counts total comments for a stream.
  """
  def count_stream_comments(stream_id) do
    from(c in Comment, where: c.stream_id == ^stream_id)
    |> Repo.aggregate(:count)
  end

  @doc """
  Searches comments by text content.
  """
  def search_comments(stream_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    search_pattern = "%#{query}%"

    from(c in Comment,
      where: c.stream_id == ^stream_id and ilike(c.comment_text, ^search_pattern),
      order_by: [desc: c.commented_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  ## Comment Classification Aggregations

  @doc """
  Returns sentiment breakdown for classified comments in a stream.

  Excludes flash_sale category comments from the totals.
  Returns a map with counts and percentages:

      %{
        positive: %{count: 156, percent: 42},
        neutral: %{count: 167, percent: 45},
        negative: %{count: 48, percent: 13},
        total: 371
      }
  """
  def get_sentiment_breakdown(stream_id) do
    results =
      from(c in Comment,
        where: c.stream_id == ^stream_id,
        where: not is_nil(c.sentiment),
        where: c.category != :flash_sale,
        group_by: c.sentiment,
        select: {c.sentiment, count(c.id)}
      )
      |> Repo.all()
      |> Map.new()

    total = Enum.reduce(results, 0, fn {_, count}, acc -> acc + count end)

    if total == 0 do
      nil
    else
      %{
        positive: build_sentiment_stat(results[:positive], total),
        neutral: build_sentiment_stat(results[:neutral], total),
        negative: build_sentiment_stat(results[:negative], total),
        total: total
      }
    end
  end

  defp build_sentiment_stat(nil, _total), do: %{count: 0, percent: 0}

  defp build_sentiment_stat(count, total) do
    %{count: count, percent: round(count / total * 100)}
  end

  @doc """
  Returns category breakdown for classified comments in a stream.

  Returns a list of category stats, each with:
  - `:category` - The category atom
  - `:count` - Number of comments
  - `:percent` - Percentage of total classified comments
  - `:unique_commenters` - Number of unique users
  - `:examples` - List of up to 2 example comments (text and username)

  Flash sale category is excluded from results.
  """
  def get_category_breakdown(stream_id) do
    # Get total classified comments (excluding flash sales)
    total =
      from(c in Comment,
        where: c.stream_id == ^stream_id,
        where: not is_nil(c.category),
        where: c.category != :flash_sale,
        select: count(c.id)
      )
      |> Repo.one()

    if total == 0 do
      []
    else
      # Get counts and unique commenters per category
      category_stats =
        from(c in Comment,
          where: c.stream_id == ^stream_id,
          where: not is_nil(c.category),
          where: c.category != :flash_sale,
          group_by: c.category,
          select: %{
            category: c.category,
            count: count(c.id),
            unique_commenters: count(c.tiktok_user_id, :distinct)
          }
        )
        |> Repo.all()

      # Fetch examples for each category
      Enum.map(category_stats, fn stat ->
        examples = get_category_examples(stream_id, stat.category, 2)

        %{
          category: stat.category,
          count: stat.count,
          percent: round(stat.count / total * 100),
          unique_commenters: stat.unique_commenters,
          examples: examples
        }
      end)
      |> Enum.sort_by(& &1.count, :desc)
    end
  end

  defp get_category_examples(stream_id, category, limit) do
    from(c in Comment,
      where: c.stream_id == ^stream_id,
      where: c.category == ^category,
      where: c.comment_text != "",
      select: %{
        text: c.comment_text,
        username: coalesce(c.tiktok_nickname, c.tiktok_username)
      },
      order_by: fragment("RANDOM()"),
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Returns the count of comments that have been classified for a stream.
  """
  def count_classified_comments(stream_id) do
    from(c in Comment,
      where: c.stream_id == ^stream_id,
      where: not is_nil(c.classified_at),
      select: count(c.id)
    )
    |> Repo.one()
  end

  @doc """
  Returns aggregate sentiment breakdown across all streams or a specific stream.

  ## Options

  - `:stream_id` - Filter to a specific stream (optional)
  """
  def get_aggregate_sentiment_breakdown(opts \\ []) do
    stream_id = Keyword.get(opts, :stream_id)

    query =
      from(c in Comment,
        where: not is_nil(c.sentiment),
        where: c.category != :flash_sale,
        group_by: c.sentiment,
        select: {c.sentiment, count(c.id)}
      )

    query =
      if stream_id do
        where(query, [c], c.stream_id == ^stream_id)
      else
        query
      end

    results =
      query
      |> Repo.all()
      |> Map.new()

    total = Enum.reduce(results, 0, fn {_, count}, acc -> acc + count end)

    if total == 0 do
      nil
    else
      %{
        positive: build_sentiment_stat(results[:positive], total),
        neutral: build_sentiment_stat(results[:neutral], total),
        negative: build_sentiment_stat(results[:negative], total),
        total: total
      }
    end
  end

  @doc """
  Returns aggregate category breakdown across all streams or a specific stream.

  ## Options

  - `:stream_id` - Filter to a specific stream (optional)
  """
  def get_aggregate_category_breakdown(opts \\ []) do
    stream_id = Keyword.get(opts, :stream_id)

    # Get total classified comments (excluding flash sales)
    total_query =
      from(c in Comment,
        where: not is_nil(c.category),
        where: c.category != :flash_sale,
        select: count(c.id)
      )

    total_query =
      if stream_id do
        where(total_query, [c], c.stream_id == ^stream_id)
      else
        total_query
      end

    total = Repo.one(total_query)

    if total == 0 do
      []
    else
      # Get counts per category
      query =
        from(c in Comment,
          where: not is_nil(c.category),
          where: c.category != :flash_sale,
          group_by: c.category,
          select: %{
            category: c.category,
            count: count(c.id)
          }
        )

      query =
        if stream_id do
          where(query, [c], c.stream_id == ^stream_id)
        else
          query
        end

      query
      |> Repo.all()
      |> Enum.map(fn stat ->
        %{
          category: stat.category,
          count: stat.count,
          percent: round(stat.count / total * 100)
        }
      end)
      |> Enum.sort_by(& &1.count, :desc)
    end
  end

  @doc """
  Lists classified comments with filtering and pagination.

  ## Options

  - `:stream_id` - Filter to a specific stream
  - `:sentiment` - Filter by sentiment (:positive, :neutral, :negative)
  - `:category` - Filter by category atom
  - `:search` - Search in comment text
  - `:page` - Page number (default 1)
  - `:per_page` - Results per page (default 25)
  """
  def list_classified_comments(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 25)
    stream_id = Keyword.get(opts, :stream_id)
    sentiment = Keyword.get(opts, :sentiment)
    category = Keyword.get(opts, :category)
    search = Keyword.get(opts, :search)

    query =
      from(c in Comment,
        where: not is_nil(c.classified_at),
        order_by: [desc: c.commented_at],
        preload: [:stream]
      )

    query = if stream_id, do: where(query, [c], c.stream_id == ^stream_id), else: query
    query = if sentiment, do: where(query, [c], c.sentiment == ^sentiment), else: query
    query = if category, do: where(query, [c], c.category == ^category), else: query

    query =
      if search && search != "" do
        search_term = "%#{search}%"
        where(query, [c], ilike(c.comment_text, ^search_term))
      else
        query
      end

    total =
      query
      |> exclude(:preload)
      |> exclude(:order_by)
      |> select([c], count(c.id))
      |> Repo.one()

    comments =
      query
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    %{
      comments: comments,
      page: page,
      total: total,
      has_more: page * per_page < total
    }
  end

  @doc """
  Returns sentiment summary for multiple streams.

  Returns a map of stream_id => %{positive_percent: N, negative_percent: N}
  """
  def get_streams_sentiment_summary(stream_ids) when is_list(stream_ids) do
    if Enum.empty?(stream_ids) do
      %{}
    else
      results =
        from(c in Comment,
          where: c.stream_id in ^stream_ids,
          where: not is_nil(c.sentiment),
          where: c.category != :flash_sale,
          group_by: [c.stream_id, c.sentiment],
          select: %{stream_id: c.stream_id, sentiment: c.sentiment, count: count(c.id)}
        )
        |> Repo.all()

      # Group by stream_id and calculate percentages
      results
      |> Enum.group_by(& &1.stream_id)
      |> Enum.map(fn {stream_id, sentiments} ->
        total = Enum.reduce(sentiments, 0, fn s, acc -> acc + s.count end)

        positive =
          Enum.find_value(sentiments, 0, fn s -> if s.sentiment == :positive, do: s.count end)

        negative =
          Enum.find_value(sentiments, 0, fn s -> if s.sentiment == :negative, do: s.count end)

        summary =
          if total > 0 do
            %{
              positive_percent: round(positive / total * 100),
              negative_percent: round(negative / total * 100)
            }
          else
            nil
          end

        {stream_id, summary}
      end)
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()
    end
  end

  ## Statistics

  @doc """
  Returns time-series statistics for a stream.
  """
  def list_stream_stats(stream_id) do
    from(s in StreamStat,
      where: s.stream_id == ^stream_id,
      order_by: [asc: s.recorded_at]
    )
    |> Repo.all()
  end

  @doc """
  Returns aggregate statistics for a stream.
  """
  def get_stream_summary(stream_id) do
    stream = get_stream!(stream_id)

    comment_count = count_stream_comments(stream_id)
    unique_commenters = count_unique_commenters(stream_id)

    duration =
      if stream.ended_at do
        DateTime.diff(stream.ended_at, stream.started_at, :second)
      else
        DateTime.diff(DateTime.utc_now(), stream.started_at, :second)
      end

    %{
      stream: stream,
      duration_seconds: duration,
      total_comments: comment_count,
      unique_commenters: unique_commenters,
      comments_per_minute: if(duration > 0, do: comment_count / (duration / 60), else: 0),
      viewer_count_peak: stream.viewer_count_peak,
      total_likes: stream.total_likes,
      total_gifts_value: stream.total_gifts_value
    }
  end

  defp count_unique_commenters(stream_id) do
    from(c in Comment,
      where: c.stream_id == ^stream_id,
      select: count(c.tiktok_user_id, :distinct)
    )
    |> Repo.one()
  end

  ## Live Status

  @doc """
  Checks if a TikTok account is currently live.

  Returns `{:ok, boolean}` or `{:error, reason}`.
  """
  def live?(unique_id) do
    Client.live?(unique_id)
  end

  @doc """
  Fetches room information for a live stream.

  Returns `{:ok, room_info}` or `{:error, reason}`.
  """
  def fetch_room_info(unique_id) do
    Client.fetch_room_info(unique_id)
  end

  ## Manual Control

  @doc """
  Manually triggers a check for live status.

  This enqueues the monitor worker to run immediately.
  """
  def check_live_status_now(source \\ "manual") do
    TiktokLiveMonitorWorker.new(%{"source" => source})
    |> Oban.insert()
  end

  @doc """
  Manually starts capture for a stream if the account is live.

  Returns `{:ok, stream}` if capture started, `{:error, reason}` otherwise.
  """
  def start_capture(unique_id) do
    case Client.fetch_room_info(unique_id) do
      {:ok, %{is_live: true, room_id: room_id} = room_info} ->
        # Check if already capturing
        case get_active_capture(room_id) do
          nil ->
            create_and_start_capture(unique_id, room_id, room_info)

          stream ->
            {:ok, stream}
        end

      {:ok, %{is_live: false}} ->
        {:error, :not_live}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stops capture for a stream.

  This marks the stream as ended in the database. The worker will detect
  this and stop the connection and event handler.
  """
  def stop_capture(stream_id) do
    stream = get_stream!(stream_id)

    stream
    |> Stream.changeset(%{
      status: :ended,
      ended_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
  end

  @doc """
  Deletes a stream and all associated data (comments, stats).

  Returns `{:ok, stream}` on success or `{:error, reason}` on failure.
  """
  def delete_stream(stream_id) do
    stream = get_stream!(stream_id)

    Ecto.Multi.new()
    |> Ecto.Multi.delete_all(:comments, from(c in Comment, where: c.stream_id == ^stream_id))
    |> Ecto.Multi.delete_all(:stats, from(s in StreamStat, where: s.stream_id == ^stream_id))
    |> Ecto.Multi.delete(:stream, stream)
    |> Repo.transaction()
    |> case do
      {:ok, %{stream: stream}} -> {:ok, stream}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Merges duplicate streams for the same room into a single stream.

  This handles race conditions where two streams were created for the same
  live broadcast. All comments and stats from the source stream are moved
  to the target stream, then the source is deleted.

  ## Parameters

  - `target_id` - The stream ID to keep (will receive merged data)
  - `source_id` - The stream ID to merge from and delete

  ## Returns

  `{:ok, target_stream}` on success, `{:error, reason}` on failure.
  """
  def merge_streams(target_id, source_id) when target_id != source_id do
    target = get_stream!(target_id)
    source = get_stream!(source_id)

    if target.room_id != source.room_id do
      {:error, :different_rooms}
    else
      do_merge_streams(target, source)
    end
  end

  defp do_merge_streams(target, source) do
    dup_comment_ids = find_duplicate_comment_ids(target.id, source.id)
    dup_stat_ids = find_duplicate_stat_ids(target.id, source.id)

    build_merge_multi(target, source, dup_comment_ids, dup_stat_ids)
    |> Repo.transaction()
    |> handle_merge_result()
  end

  defp find_duplicate_comment_ids(target_id, source_id) do
    from(sc in Comment,
      join: tc in Comment,
      on:
        tc.stream_id == ^target_id and
          sc.tiktok_user_id == tc.tiktok_user_id and
          sc.commented_at == tc.commented_at,
      where: sc.stream_id == ^source_id,
      select: sc.id
    )
    |> Repo.all()
  end

  defp find_duplicate_stat_ids(target_id, source_id) do
    from(ss in StreamStat,
      join: ts in StreamStat,
      on: ts.stream_id == ^target_id and ss.recorded_at == ts.recorded_at,
      where: ss.stream_id == ^source_id,
      select: ss.id
    )
    |> Repo.all()
  end

  defp build_merge_multi(target, source, dup_comment_ids, dup_stat_ids) do
    Ecto.Multi.new()
    |> Ecto.Multi.delete_all(
      :delete_dup_comments,
      from(c in Comment, where: c.id in ^dup_comment_ids)
    )
    |> Ecto.Multi.delete_all(
      :delete_dup_stats,
      from(s in StreamStat, where: s.id in ^dup_stat_ids)
    )
    |> Ecto.Multi.update_all(
      :move_comments,
      from(c in Comment, where: c.stream_id == ^source.id),
      set: [stream_id: target.id]
    )
    |> Ecto.Multi.update_all(
      :move_stats,
      from(s in StreamStat, where: s.stream_id == ^source.id),
      set: [stream_id: target.id]
    )
    |> Ecto.Multi.update(:update_target, merge_stream_changeset(target, source))
    |> Ecto.Multi.delete(:delete_source, source)
  end

  defp merge_stream_changeset(target, source) do
    Stream.changeset(target, %{
      started_at: earlier_datetime(target.started_at, source.started_at),
      ended_at: later_datetime(target.ended_at, source.ended_at),
      viewer_count_peak: max(target.viewer_count_peak || 0, source.viewer_count_peak || 0),
      total_likes: max(target.total_likes || 0, source.total_likes || 0),
      total_comments: (target.total_comments || 0) + (source.total_comments || 0),
      total_gifts_value: (target.total_gifts_value || 0) + (source.total_gifts_value || 0)
    })
  end

  defp handle_merge_result({:ok, %{update_target: updated_target}}), do: {:ok, updated_target}
  defp handle_merge_result({:error, step, reason, _changes}), do: {:error, {step, reason}}

  defp earlier_datetime(nil, dt), do: dt
  defp earlier_datetime(dt, nil), do: dt

  defp earlier_datetime(dt1, dt2) do
    if DateTime.compare(dt1, dt2) == :lt, do: dt1, else: dt2
  end

  defp later_datetime(nil, dt), do: dt
  defp later_datetime(dt, nil), do: dt

  defp later_datetime(dt1, dt2) do
    if DateTime.compare(dt1, dt2) == :gt, do: dt1, else: dt2
  end

  ## Private Helpers

  defp apply_filters(query, opts) do
    Enum.reduce(opts, query, fn
      {:search, search_term}, q ->
        pattern = "%#{search_term}%"

        # Search across unique_id, title, and formatted started_at (day name + time)
        where(
          q,
          [s],
          ilike(s.unique_id, ^pattern) or
            ilike(s.title, ^pattern) or
            ilike(fragment("to_char(?, 'FMDay')", s.started_at), ^pattern) or
            ilike(fragment("to_char(?, 'HH12:MI AM')", s.started_at), ^pattern)
        )

      {:status, status}, q ->
        where(q, [s], s.status == ^status)

      {:unique_id, unique_id}, q ->
        where(q, [s], s.unique_id == ^unique_id)

      {:started_after, datetime}, q ->
        where(q, [s], s.started_at >= ^datetime)

      {:started_before, datetime}, q ->
        where(q, [s], s.started_at <= ^datetime)

      {:limit, limit}, q ->
        limit(q, ^limit)

      {:offset, offset}, q ->
        offset(q, ^offset)

      _, q ->
        q
    end)
  end

  defp apply_sorting(query, opts) do
    sort_by = Keyword.get(opts, :sort_by, "started")
    sort_dir = Keyword.get(opts, :sort_dir, "desc")

    dir = if sort_dir == "asc", do: :asc, else: :desc

    case sort_by do
      "started" ->
        order_by(query, [s], [{^dir, s.started_at}])

      "viewers" ->
        order_by(query, [s], [{^dir, coalesce(s.viewer_count_peak, 0)}, {^dir, s.started_at}])

      "gmv" ->
        order_by(query, [s], [{^dir, coalesce(s.gmv_cents, 0)}, {^dir, s.started_at}])

      "comments" ->
        order_by(query, [s], [{^dir, coalesce(s.total_comments, 0)}, {^dir, s.started_at}])

      "duration" ->
        # Duration is calculated as ended_at - started_at
        # For ongoing streams (ended_at is nil), treat as 0 for sorting
        order_by(
          query,
          [s],
          [
            {^dir,
             fragment(
               "COALESCE(EXTRACT(EPOCH FROM (? - ?)), 0)",
               s.ended_at,
               s.started_at
             )},
            {^dir, s.started_at}
          ]
        )

      _ ->
        # Default to started_at desc
        order_by(query, [s], [{^dir, s.started_at}])
    end
  end

  defp get_active_capture(room_id) do
    from(s in Stream,
      where: s.room_id == ^room_id and s.status == :capturing,
      limit: 1
    )
    |> Repo.one()
  end

  defp create_and_start_capture(unique_id, room_id, room_info) do
    stream_attrs = %{
      room_id: room_id,
      unique_id: unique_id,
      title: room_info[:title],
      started_at: DateTime.utc_now() |> DateTime.truncate(:second),
      status: :capturing,
      viewer_count_peak: room_info[:viewer_count] || 0,
      raw_metadata: Map.drop(room_info, [:is_live])
    }

    case %Stream{} |> Stream.changeset(stream_attrs) |> Repo.insert() do
      {:ok, stream} ->
        # Enqueue the stream worker
        %{stream_id: stream.id, unique_id: unique_id}
        |> TiktokLiveStreamWorker.new()
        |> Oban.insert()

        {:ok, stream}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  ## Session-Stream Linking

  @doc """
  Links a stream to a session.

  ## Options

  - `:linked_by` - "manual" (default) or "auto"
  - `:parse_comments` - If true (default), parses comments for product numbers

  Returns `{:ok, session_stream}` or `{:error, changeset}`.
  """
  def link_stream_to_session(stream_id, session_id, opts \\ []) do
    linked_by = Keyword.get(opts, :linked_by, "manual")
    parse_comments = Keyword.get(opts, :parse_comments, true)

    result =
      %SessionStream{}
      |> SessionStream.changeset(%{
        stream_id: stream_id,
        session_id: session_id,
        linked_at: DateTime.utc_now() |> DateTime.truncate(:second),
        linked_by: linked_by
      })
      |> Repo.insert()

    case result do
      {:ok, session_stream} ->
        if parse_comments do
          parse_comments_for_session(stream_id, session_id)
        end

        {:ok, session_stream}

      error ->
        error
    end
  end

  @doc """
  Unlinks a stream from a session.

  Also clears parsed product associations from comments.
  """
  def unlink_stream_from_session(stream_id, session_id) do
    # Clear session_product_id from comments for this stream+session combo
    clear_parsed_products_for_link(stream_id, session_id)

    from(ss in SessionStream,
      where: ss.stream_id == ^stream_id and ss.session_id == ^session_id
    )
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Gets all sessions linked to a stream.
  """
  def get_linked_sessions(stream_id) do
    from(ss in SessionStream,
      where: ss.stream_id == ^stream_id,
      join: s in assoc(ss, :session),
      preload: [session: {s, :session_products}],
      order_by: [desc: ss.linked_at]
    )
    |> Repo.all()
    |> Enum.map(& &1.session)
  end

  @doc """
  Gets all streams linked to a session.
  """
  def get_linked_streams(session_id) do
    from(ss in SessionStream,
      where: ss.session_id == ^session_id,
      join: st in assoc(ss, :stream),
      preload: [stream: st],
      order_by: [desc: ss.linked_at]
    )
    |> Repo.all()
    |> Enum.map(& &1.stream)
  end

  @doc """
  Detects which session was actively used during a stream based on session_state updates.

  Returns the session whose state was updated during the stream's time window.
  If multiple sessions were active, returns the one with the most recent update
  (indicating it was the primary/last session used).

  Returns `{:ok, session}` if a session was detected, `:none` otherwise.
  """
  def detect_active_session(stream_id) do
    stream = get_stream!(stream_id)

    # Stream must have both started_at and ended_at to detect session
    if is_nil(stream.started_at) or is_nil(stream.ended_at) do
      :none
    else
      # Find session_states that were updated during the stream window
      # Order by most recent update (the primary session being used at stream end)
      query =
        from(ss in Pavoi.Sessions.SessionState,
          where: ss.updated_at >= ^stream.started_at,
          where: ss.updated_at <= ^stream.ended_at,
          join: s in assoc(ss, :session),
          order_by: [desc: ss.updated_at],
          limit: 1,
          select: s
        )

      case Repo.one(query) do
        nil -> :none
        session -> {:ok, session}
      end
    end
  end

  @doc """
  Attempts to auto-link a stream to a session based on session controller activity.

  This should be called when a stream ends. It detects which session was being
  used during the stream and automatically links them.

  Returns `{:ok, session_stream}` if auto-linked, `:none` if no session detected,
  or `{:already_linked, session}` if the stream is already linked to a session.
  """
  def auto_link_stream_to_session(stream_id) do
    # Check if already linked
    case get_linked_sessions(stream_id) do
      [session | _] ->
        {:already_linked, session}

      [] ->
        case detect_active_session(stream_id) do
          {:ok, session} ->
            Logger.info(
              "Auto-linking stream #{stream_id} to session #{session.id} (#{session.name})"
            )

            link_stream_to_session(stream_id, session.id, linked_by: "auto")

          :none ->
            :none
        end
    end
  end

  ## Comment Parsing

  @doc """
  Parses product numbers from comments and links them to session products.

  Patterns recognized:
  - Hash patterns: #25, #3
  - Standalone numbers: 25, 3 (1-3 digits)

  Only parses comments for the given stream.
  """
  def parse_comments_for_session(stream_id, session_id) do
    # Get session products to build position map
    session_products =
      from(sp in SessionProduct,
        where: sp.session_id == ^session_id,
        select: {sp.position, sp.id}
      )
      |> Repo.all()
      |> Map.new()

    max_position =
      if Enum.empty?(session_products), do: 0, else: Enum.max(Map.keys(session_products))

    # Get all comments for this stream that haven't been parsed yet
    comments =
      from(c in Comment,
        where: c.stream_id == ^stream_id and is_nil(c.session_product_id),
        select: [:id, :comment_text]
      )
      |> Repo.all()

    # Parse and update each comment
    parsed_count =
      Enum.reduce(comments, 0, fn comment, count ->
        case parse_product_number(comment.comment_text, max_position) do
          {:ok, product_number} ->
            session_product_id = Map.get(session_products, product_number)

            from(c in Comment, where: c.id == ^comment.id)
            |> Repo.update_all(
              set: [
                parsed_product_number: product_number,
                session_product_id: session_product_id
              ]
            )

            count + 1

          :no_match ->
            count
        end
      end)

    {:ok, parsed_count}
  end

  @doc """
  Parses a product number from comment text.

  Returns `{:ok, number}` or `:no_match`.
  """
  def parse_product_number(text, max_position) when max_position > 0 do
    # Patterns in order of specificity:
    # 1. Hash pattern: #25 (most specific)
    # 2. Standalone number with word boundaries
    patterns = [
      # #25, #3 - hash prefix (most specific)
      ~r/(?:^|[^a-zA-Z0-9])#(\d{1,3})(?:[^0-9]|$)/,
      # Standalone number: 25, 3 (word boundaries)
      ~r/(?:^|[^0-9])(\d{1,3})(?:[^0-9]|$)/
    ]

    Enum.find_value(patterns, fn pattern ->
      try_extract_product_number(pattern, text, max_position)
    end) || :no_match
  end

  def parse_product_number(_text, _max_position), do: :no_match

  defp try_extract_product_number(pattern, text, max_position) do
    with [_, number_str] <- Regex.run(pattern, text),
         number = String.to_integer(number_str),
         true <- number > 0 and number <= max_position do
      {:ok, number}
    else
      _ -> nil
    end
  end

  defp clear_parsed_products_for_link(stream_id, session_id) do
    # Get session product IDs for this session
    session_product_ids =
      from(sp in SessionProduct,
        where: sp.session_id == ^session_id,
        select: sp.id
      )
      |> Repo.all()

    # Clear only comments that were linked to this session's products
    from(c in Comment,
      where: c.stream_id == ^stream_id,
      where: c.session_product_id in ^session_product_ids
    )
    |> Repo.update_all(set: [session_product_id: nil, parsed_product_number: nil])
  end

  ## Product Interest Analytics

  @doc """
  Gets product interest summary for a stream.

  Returns counts of comments per product number for the given session.
  """
  def get_product_interest_summary(stream_id, session_id) do
    from(c in Comment,
      where: c.stream_id == ^stream_id,
      where: not is_nil(c.parsed_product_number),
      join: sp in SessionProduct,
      on: sp.session_id == ^session_id and sp.position == c.parsed_product_number,
      left_join: p in assoc(sp, :product),
      group_by: [c.parsed_product_number, sp.id, sp.product_id, p.name],
      select: %{
        product_number: c.parsed_product_number,
        session_product_id: sp.id,
        product_id: sp.product_id,
        product_name: p.name,
        comment_count: count(c.id)
      },
      order_by: [desc: count(c.id)]
    )
    |> Repo.all()
  end
end
