defmodule Pavoi.TiktokLive.EventHandler do
  @moduledoc """
  Handles events from TikTok live streams and persists them to the database.

  This GenServer:
  - Subscribes to TikTok live events via PubSub
  - Batches events for efficient database insertion
  - Updates stream statistics periodically
  - Broadcasts events to UI via stream-specific PubSub topics

  ## Usage

      {:ok, pid} = EventHandler.start_link(stream_id: 1)

  """

  use GenServer

  require Logger

  alias Pavoi.Repo
  alias Pavoi.TiktokLive.{Comment, Stream, StreamProduct, StreamStat}
  alias Pavoi.Workers.StreamReportWorker

  @batch_size 50
  @batch_flush_interval_ms 1_000
  @stats_interval_ms 30_000
  # Max msg_ids to track for deduplication (prevents unbounded memory growth)
  @max_seen_msg_ids 5_000
  # Only persist viewer count to DB every N ms (reduces query spam)
  @viewer_count_persist_interval_ms 5_000

  defmodule State do
    @moduledoc false
    defstruct [
      :stream_id,
      :stream,
      :comment_batch,
      :stats,
      :flush_timer_ref,
      :stats_timer_ref,
      :seen_msg_ids,
      :last_viewer_count_persist
    ]
  end

  # Client API

  @doc """
  Starts the event handler for a specific stream.

  ## Options

  - `:stream_id` - Required. Database ID of the stream to handle events for.
  - `:name` - Optional. Process name for registration.
  """
  def start_link(opts) do
    stream_id = Keyword.fetch!(opts, :stream_id)
    name = Keyword.get(opts, :name)

    GenServer.start_link(__MODULE__, stream_id, name: name)
  end

  @doc """
  Stops the event handler and flushes any remaining events.
  """
  def stop(pid) do
    GenServer.call(pid, :stop)
  end

  @doc """
  Returns current statistics for the stream.
  """
  def get_stats(pid) do
    GenServer.call(pid, :get_stats)
  end

  # Server callbacks

  @impl GenServer
  def init(stream_id) do
    Logger.info("Starting event handler for stream #{stream_id}")

    # Subscribe to TikTok live events
    Phoenix.PubSub.subscribe(Pavoi.PubSub, "tiktok_live:events")

    # Load stream record
    stream = Repo.get!(Stream, stream_id)

    state = %State{
      stream_id: stream_id,
      stream: stream,
      comment_batch: [],
      stats: %{
        viewer_count: 0,
        viewer_count_peak: stream.viewer_count_peak || 0,
        like_count: 0,
        gift_count: 0,
        gift_value: 0,
        comment_count: stream.total_comments || 0
      },
      flush_timer_ref: schedule_flush(),
      stats_timer_ref: schedule_stats_save(),
      seen_msg_ids: MapSet.new(),
      last_viewer_count_persist: System.monotonic_time(:millisecond)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_info({:tiktok_live_event, stream_id, event}, %{stream_id: stream_id} = state) do
    # Only process events for our stream
    new_state = process_event(event, state)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info({:tiktok_live_event, _other_stream_id, _event}, state) do
    # Ignore events from other streams
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:flush_batch, state) do
    new_state = flush_comment_batch(state)
    {:noreply, %{new_state | flush_timer_ref: schedule_flush()}}
  end

  @impl GenServer
  def handle_info(:save_stats, state) do
    new_state = save_stats_snapshot(state)
    {:noreply, %{new_state | stats_timer_ref: schedule_stats_save()}}
  end

  @impl GenServer
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:stop, _from, state) do
    # Flush remaining events
    state = flush_comment_batch(state)
    state = save_stats_snapshot(state)

    # Cancel timers
    cancel_timer(state.flush_timer_ref)
    cancel_timer(state.stats_timer_ref)

    {:stop, :normal, :ok, state}
  end

  @impl GenServer
  def handle_call(:get_stats, _from, state) do
    {:reply, state.stats, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    # Final flush on termination
    flush_comment_batch(state)
    save_stats_snapshot(state)
    :ok
  end

  # Event processing

  defp process_event(%{type: :comment} = event, state) do
    msg_id = event[:msg_id]

    # Skip if we've already seen this message (prevents duplicate UI broadcasts)
    if msg_id && MapSet.member?(state.seen_msg_ids, msg_id) do
      state
    else
      # Add comment to batch
      comment_attrs = %{
        stream_id: state.stream_id,
        tiktok_user_id: event.user_id,
        tiktok_username: event.username,
        tiktok_nickname: event.nickname,
        comment_text: event.content,
        commented_at: event.timestamp,
        raw_event: sanitize_raw_event(event.raw)
      }

      new_batch = [comment_attrs | state.comment_batch]
      new_stats = %{state.stats | comment_count: state.stats.comment_count + 1}

      # Track seen msg_id (only if present), reset if too large
      new_seen = update_seen_msg_ids(state.seen_msg_ids, msg_id)

      # Broadcast to UI
      broadcast_to_stream(state.stream_id, {:comment, event})

      # Flush if batch is full
      new_state = %{state | comment_batch: new_batch, stats: new_stats, seen_msg_ids: new_seen}

      if length(new_batch) >= @batch_size do
        flush_comment_batch(new_state)
      else
        new_state
      end
    end
  end

  defp process_event(%{type: :viewer_count} = event, state) do
    viewer_count = event.viewer_count || 0
    peak = max(state.stats.viewer_count_peak, viewer_count)

    new_stats = %{
      state.stats
      | viewer_count: viewer_count,
        viewer_count_peak: peak
    }

    # Always broadcast to UI for real-time display
    broadcast_to_stream(state.stream_id, {:viewer_count, viewer_count})

    # Only persist to DB periodically (reduces query spam significantly)
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.last_viewer_count_persist

    if elapsed >= @viewer_count_persist_interval_ms do
      updates =
        if peak > state.stream.viewer_count_peak do
          %{viewer_count_current: viewer_count, viewer_count_peak: peak}
        else
          %{viewer_count_current: viewer_count}
        end

      state.stream
      |> Stream.changeset(updates)
      |> Repo.update(log: false)

      %{state | stats: new_stats, last_viewer_count_persist: now}
    else
      %{state | stats: new_stats}
    end
  end

  defp process_event(%{type: :like} = event, state) do
    total = event.total_count || state.stats.like_count + (event.count || 1)
    new_stats = %{state.stats | like_count: total}

    broadcast_to_stream(state.stream_id, {:like, event})

    %{state | stats: new_stats}
  end

  defp process_event(%{type: :gift} = event, state) do
    diamond_count = event.diamond_count || 0

    new_stats = %{
      state.stats
      | gift_count: state.stats.gift_count + 1,
        gift_value: state.stats.gift_value + diamond_count
    }

    broadcast_to_stream(state.stream_id, {:gift, event})

    %{state | stats: new_stats}
  end

  defp process_event(%{type: :join} = event, state) do
    broadcast_to_stream(state.stream_id, {:join, event})
    state
  end

  defp process_event(%{type: :follow} = event, state) do
    broadcast_to_stream(state.stream_id, {:follow, event})
    state
  end

  defp process_event(%{type: :stream_ended}, state) do
    Logger.info("Stream #{state.stream_id} ended")
    broadcast_to_stream(state.stream_id, {:stream_ended})

    case Pavoi.TiktokLive.mark_stream_ended(state.stream_id) do
      {:ok, :ended} ->
        # Auto-link to session if one was active during the stream
        auto_link_stream(state.stream_id)

        # Enqueue Slack report job for the completed stream
        enqueue_stream_report(state.stream_id)

      {:error, :already_ended} ->
        Logger.debug("Stream #{state.stream_id} already ended, skipping report enqueue")
    end

    state
  end

  defp process_event(%{type: :connected}, state) do
    broadcast_to_stream(state.stream_id, {:connected})
    state
  end

  defp process_event(%{type: :thumbnail, thumbnail_base64: base64}, state) do
    # Decode and upload thumbnail to storage
    Task.start(fn ->
      case upload_thumbnail(state.stream_id, base64) do
        {:ok, key} ->
          Logger.info("Thumbnail uploaded for stream #{state.stream_id}: #{key}")

          # Update stream with the storage key
          state.stream
          |> Stream.changeset(%{cover_image_key: key})
          |> Repo.update()

        {:error, reason} ->
          Logger.warning(
            "Failed to upload thumbnail for stream #{state.stream_id}: #{inspect(reason)}"
          )
      end
    end)

    state
  end

  defp process_event(%{type: :disconnected} = event, state) do
    Logger.info("Stream #{state.stream_id} disconnected: #{inspect(event[:reason])}")
    broadcast_to_stream(state.stream_id, {:disconnected, event[:reason]})

    # Mark stream as ended on disconnect (the worker will also handle cleanup)
    case Pavoi.TiktokLive.mark_stream_ended(state.stream_id) do
      {:ok, :ended} ->
        # Auto-link to session if one was active during the stream
        auto_link_stream(state.stream_id)

        # Enqueue Slack report job for the completed stream
        enqueue_stream_report(state.stream_id)

      {:error, :already_ended} ->
        Logger.debug("Stream #{state.stream_id} already ended, skipping report enqueue")
    end

    state
  end

  defp process_event(%{type: :connection_failed}, state) do
    Logger.error("Connection failed for stream #{state.stream_id}")
    broadcast_to_stream(state.stream_id, {:connection_failed})

    # Mark stream as failed
    update_stream_field(state.stream, :status, :failed)

    state
  end

  # Shopping/Product events - save products to database
  defp process_event(%{type: :shopping, products: products}, state)
       when is_list(products) and length(products) > 0 do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Save each product to the database
    Enum.each(products, fn product ->
      upsert_stream_product(state.stream_id, product, now)
    end)

    Logger.info("Saved #{length(products)} products for stream #{state.stream_id}")
    broadcast_to_stream(state.stream_id, {:shopping, products})
    state
  end

  defp process_event(%{type: :shopping} = event, state) do
    Logger.debug("Shopping event with no products for stream #{state.stream_id}")
    broadcast_to_stream(state.stream_id, {:shopping, event})
    state
  end

  defp process_event(%{type: :live_intro} = event, state) do
    Logger.info("Live intro for stream #{state.stream_id}: #{inspect(event[:description])}")
    broadcast_to_stream(state.stream_id, {:live_intro, event})
    state
  end

  defp process_event(%{type: :envelope} = event, state) do
    broadcast_to_stream(state.stream_id, {:envelope, event})
    state
  end

  defp process_event(%{type: :raw_shopping} = event, state) do
    Logger.info("Raw shopping (#{event.message_type}) for stream #{state.stream_id}")
    broadcast_to_stream(state.stream_id, {:raw_shopping, event})
    state
  end

  defp process_event(%{type: type} = event, state) do
    # Silently broadcast unhandled event types (social, etc.)
    broadcast_to_stream(state.stream_id, {type, event})
    state
  end

  defp update_seen_msg_ids(seen_msg_ids, nil), do: seen_msg_ids

  defp update_seen_msg_ids(seen_msg_ids, msg_id) do
    # Reset if we've accumulated too many (duplicates come in quick succession anyway)
    seen = if MapSet.size(seen_msg_ids) >= @max_seen_msg_ids, do: MapSet.new(), else: seen_msg_ids
    MapSet.put(seen, msg_id)
  end

  # Batch operations

  defp flush_comment_batch(%{comment_batch: []} = state), do: state

  defp flush_comment_batch(state) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    # Add timestamps for batch insert
    comments =
      state.comment_batch
      |> Enum.map(fn attrs ->
        attrs
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)

    case Repo.insert_all(Comment, comments,
           on_conflict: :nothing,
           conflict_target: [:stream_id, :tiktok_user_id, :commented_at],
           log: false
         ) do
      {count, _} when count > 0 ->
        # Update total comment count on stream (silent - high frequency)
        update_stream_field(state.stream, :total_comments, state.stats.comment_count, log: false)

      _ ->
        :ok
    end

    %{state | comment_batch: []}
  end

  defp save_stats_snapshot(state) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    stat_attrs = %{
      stream_id: state.stream_id,
      recorded_at: now,
      viewer_count: state.stats.viewer_count,
      like_count: state.stats.like_count,
      gift_count: state.stats.gift_count,
      comment_count: state.stats.comment_count
    }

    case %StreamStat{} |> StreamStat.changeset(stat_attrs) |> Repo.insert() do
      {:ok, _} ->
        Logger.debug("Saved stats snapshot for stream #{state.stream_id}")

      {:error, changeset} ->
        Logger.warning("Failed to save stats: #{inspect(changeset.errors)}")
    end

    # Update aggregate stats on stream record
    stream = state.stream

    Repo.transaction(fn ->
      stream
      |> Stream.changeset(%{
        total_likes: state.stats.like_count,
        total_gifts_value: state.stats.gift_value,
        viewer_count_peak: state.stats.viewer_count_peak
      })
      |> Repo.update()
    end)

    state
  end

  # Helper functions

  defp schedule_flush do
    Process.send_after(self(), :flush_batch, @batch_flush_interval_ms)
  end

  defp schedule_stats_save do
    Process.send_after(self(), :save_stats, @stats_interval_ms)
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp update_stream_field(stream, field, value, opts \\ []) do
    stream
    |> Stream.changeset(%{field => value})
    |> Repo.update(opts)
  end

  defp upsert_stream_product(_stream_id, %{tiktok_product_id: nil}, _now), do: :ok
  defp upsert_stream_product(_stream_id, %{tiktok_product_id: ""}, _now), do: :ok

  defp upsert_stream_product(stream_id, product, now) do
    attrs = %{
      stream_id: stream_id,
      tiktok_product_id: product.tiktok_product_id,
      title: product[:title],
      price_cents: product[:price_cents],
      image_url: product[:image_url],
      first_seen_at: now,
      showcase_count: 1
    }

    Repo.insert(
      StreamProduct.changeset(%StreamProduct{}, attrs),
      on_conflict: [inc: [showcase_count: 1]],
      conflict_target: [:stream_id, :tiktok_product_id]
    )
  end

  defp broadcast_to_stream(stream_id, event) do
    Phoenix.PubSub.broadcast(
      Pavoi.PubSub,
      "tiktok_live:stream:#{stream_id}",
      {:tiktok_live_stream_event, event}
    )
  end

  defp sanitize_raw_event(raw) when is_struct(raw) do
    # Convert protobuf struct to map for JSON storage
    raw
    |> Map.from_struct()
    |> Map.drop([:__struct__, :__unknown_fields__])
    |> Enum.reject(fn {_k, v} -> is_struct(v) end)
    |> Map.new()
  rescue
    _ -> %{}
  end

  defp sanitize_raw_event(_), do: %{}

  defp upload_thumbnail(stream_id, base64_data) do
    binary = Base.decode64!(base64_data)
    key = "streams/#{stream_id}/thumbnail.jpg"
    Pavoi.Storage.upload_binary(key, binary, "image/jpeg")
  end

  defp auto_link_stream(stream_id) do
    case Pavoi.TiktokLive.auto_link_stream_to_session(stream_id) do
      {:ok, _session_stream} ->
        Logger.info("Stream #{stream_id} auto-linked to session")

      {:already_linked, session} ->
        Logger.debug("Stream #{stream_id} already linked to session #{session.id}")

      :none ->
        Logger.debug("No active session detected for stream #{stream_id}")

      {:error, reason} ->
        Logger.warning("Failed to auto-link stream #{stream_id}: #{inspect(reason)}")
    end
  end

  defp enqueue_stream_report(stream_id) do
    Logger.info("Enqueueing stream report for stream #{stream_id}")

    %{stream_id: stream_id}
    |> StreamReportWorker.new()
    |> Oban.insert()
  end
end
