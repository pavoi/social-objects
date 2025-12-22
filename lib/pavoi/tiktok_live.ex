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

  require Logger

  alias Pavoi.Catalog.Product
  alias Pavoi.Repo
  alias Pavoi.Sessions.{Session, SessionProduct}
  alias Pavoi.TiktokLive.{Client, Comment, SessionStream, Stream, StreamProduct, StreamStat}
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
  Updates a stream's cover image by downloading from URL and uploading to storage.

  This is typically called when we receive the connected event from the bridge,
  which includes the cover image URL from TikTok's roomInfo.

  Returns `{:ok, stream}` on success, `{:error, reason}` on failure.
  """
  def update_stream_cover(stream_id, cover_url) when is_binary(cover_url) do
    stream = get_stream!(stream_id)

    # Skip if stream already has a cover image
    if stream.cover_image_url do
      {:ok, stream}
    else
      # Generate storage key for the cover image
      storage_key = "streams/#{stream_id}/cover.jpg"

      case Pavoi.Storage.upload_from_url(cover_url, storage_key) do
        {:ok, _key} ->
          # Get the public URL and update stream
          public_url = Pavoi.Storage.public_url(storage_key)

          stream
          |> Stream.changeset(%{cover_image_url: public_url})
          |> Repo.update()

        {:error, reason} ->
          Logger.warning(
            "Failed to upload cover image for stream #{stream_id}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    end
  end

  def update_stream_cover(_stream_id, nil), do: {:ok, nil}
  def update_stream_cover(_stream_id, _), do: {:ok, nil}

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

    result =
      Enum.find_value(patterns, fn pattern ->
        case Regex.run(pattern, text) do
          [_, number_str] ->
            number = String.to_integer(number_str)

            # Validate: must be positive and within session range
            if number > 0 and number <= max_position do
              {:ok, number}
            else
              nil
            end

          _ ->
            nil
        end
      end)

    result || :no_match
  end

  def parse_product_number(_text, _max_position), do: :no_match

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
      group_by: [c.parsed_product_number, sp.id, p.name],
      select: %{
        product_number: c.parsed_product_number,
        session_product_id: sp.id,
        product_name: p.name,
        comment_count: count(c.id)
      },
      order_by: [desc: count(c.id)]
    )
    |> Repo.all()
  end

  ## Session Suggestions (based on product overlap)

  @doc """
  Returns suggested sessions for a stream based on product overlap.

  Matching algorithm:
  1. Get all TikTok product IDs showcased in the stream
  2. Find internal products where those IDs exist in tiktok_product_ids array
  3. Find sessions containing those products
  4. Score each session: matched_products / total_session_products

  ## Options

  - `:limit` - Maximum suggestions to return (default: 5)

  Returns a list of maps with :session, :matched_count, :total_count, :match_score
  """
  def get_suggested_sessions(stream_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)

    # Get TikTok product IDs showcased in this stream
    stream_product_ids = get_stream_product_ids(stream_id)

    if Enum.empty?(stream_product_ids) do
      []
    else
      suggest_sessions_by_products(stream_product_ids, stream_id, limit)
    end
  end

  defp get_stream_product_ids(stream_id) do
    from(sp in StreamProduct,
      where: sp.stream_id == ^stream_id,
      select: sp.tiktok_product_id
    )
    |> Repo.all()
  end

  defp suggest_sessions_by_products(tiktok_product_ids, stream_id, limit) do
    # Find internal products matching these TikTok IDs
    # Uses array overlap operator (&&) for tiktok_product_ids array
    # Also checks the single tiktok_product_id field
    matching_product_ids =
      from(p in Product,
        where:
          fragment("? && ?", p.tiktok_product_ids, ^tiktok_product_ids) or
            p.tiktok_product_id in ^tiktok_product_ids,
        select: p.id
      )
      |> Repo.all()

    if Enum.empty?(matching_product_ids) do
      []
    else
      # Get already linked session IDs to exclude
      linked_session_ids = get_linked_session_ids(stream_id)

      # Find sessions containing matching products and count matches
      from(s in Session,
        join: sp in SessionProduct,
        on: sp.session_id == s.id,
        where: sp.product_id in ^matching_product_ids,
        where: s.id not in ^linked_session_ids,
        group_by: s.id,
        select: %{
          session: s,
          matched_count: count(sp.id, :distinct)
        },
        order_by: [desc: count(sp.id, :distinct)],
        limit: ^limit
      )
      |> Repo.all()
      |> Enum.map(fn %{session: session, matched_count: matched_count} ->
        # Get total products in session
        total_count = get_session_product_count(session.id)

        %{
          session: session,
          matched_count: matched_count,
          total_count: total_count,
          match_score: if(total_count > 0, do: matched_count / total_count, else: 0)
        }
      end)
    end
  end

  defp get_linked_session_ids(stream_id) do
    from(ss in SessionStream,
      where: ss.stream_id == ^stream_id,
      select: ss.session_id
    )
    |> Repo.all()
  end

  defp get_session_product_count(session_id) do
    from(sp in SessionProduct,
      where: sp.session_id == ^session_id,
      select: count(sp.id)
    )
    |> Repo.one() || 0
  end
end
