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

      config :pavoi, :euler_stream_api_key, System.get_env("EULER_STREAM_API_KEY")

      config :pavoi, :tiktok_live_monitor,
        accounts: ["pavoi"]

  """

  import Ecto.Query, warn: false

  alias Pavoi.Repo
  alias Pavoi.TiktokLive.{Client, Comment, Stream, StreamStat}
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
  - `:limit` - Limit number of results
  - `:offset` - Offset for pagination
  """
  def list_streams(opts) do
    Stream
    |> apply_filters(opts)
    |> order_by([s], desc: s.started_at)
    |> Repo.all()
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
  def check_live_status_now do
    TiktokLiveMonitorWorker.new(%{})
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

    # Verify they're for the same room
    if target.room_id != source.room_id do
      {:error, :different_rooms}
    else
      # Find comments in source that would conflict with target (same user + timestamp)
      # These are duplicates captured by both streams
      duplicate_comment_ids =
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

      # Find stats in source that would conflict with target (same timestamp)
      duplicate_stat_ids =
        from(ss in StreamStat,
          join: ts in StreamStat,
          on: ts.stream_id == ^target_id and ss.recorded_at == ts.recorded_at,
          where: ss.stream_id == ^source_id,
          select: ss.id
        )
        |> Repo.all()

      Ecto.Multi.new()
      # Delete duplicate comments from source (already exist in target)
      |> Ecto.Multi.delete_all(
        :delete_dup_comments,
        from(c in Comment, where: c.id in ^duplicate_comment_ids)
      )
      # Delete duplicate stats from source (already exist in target)
      |> Ecto.Multi.delete_all(
        :delete_dup_stats,
        from(s in StreamStat, where: s.id in ^duplicate_stat_ids)
      )
      # Move remaining unique comments from source to target
      |> Ecto.Multi.update_all(
        :move_comments,
        from(c in Comment, where: c.stream_id == ^source_id),
        set: [stream_id: target_id]
      )
      # Move remaining unique stats from source to target
      |> Ecto.Multi.update_all(
        :move_stats,
        from(s in StreamStat, where: s.stream_id == ^source_id),
        set: [stream_id: target_id]
      )
      # Update target with best values from both streams
      |> Ecto.Multi.update(:update_target, fn _changes ->
        Stream.changeset(target, %{
          started_at: earlier_datetime(target.started_at, source.started_at),
          ended_at: later_datetime(target.ended_at, source.ended_at),
          viewer_count_peak: max(target.viewer_count_peak || 0, source.viewer_count_peak || 0),
          total_likes: max(target.total_likes || 0, source.total_likes || 0),
          total_comments: (target.total_comments || 0) + (source.total_comments || 0),
          total_gifts_value: (target.total_gifts_value || 0) + (source.total_gifts_value || 0)
        })
      end)
      # Delete the source stream
      |> Ecto.Multi.delete(:delete_source, source)
      |> Repo.transaction()
      |> case do
        {:ok, %{update_target: updated_target}} -> {:ok, updated_target}
        {:error, step, reason, _changes} -> {:error, {step, reason}}
      end
    end
  end

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
end
