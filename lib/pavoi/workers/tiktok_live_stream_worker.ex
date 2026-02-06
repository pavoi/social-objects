defmodule Pavoi.Workers.TiktokLiveStreamWorker do
  @moduledoc """
  Oban worker that manages the capture process for a single TikTok live stream.

  This worker:
  1. Connects to the TikTok Bridge via HTTP API
  2. Subscribes to bridge events via PubSub
  3. Translates events from unique_id to stream_id format
  4. Starts the Event Handler for persisting events
  5. Runs until the stream ends or connection fails

  The worker is designed to be long-running (up to several hours for a live stream).
  It uses Oban's snooze mechanism to periodically check if the stream is still active.
  """

  use Oban.Worker,
    queue: :tiktok,
    max_attempts: 3,
    unique: [period: :infinity, keys: [:stream_id], states: [:available, :scheduled, :executing]]

  require Logger

  alias Pavoi.Repo
  alias Pavoi.TiktokLive.{BridgeClient, EventHandler, Stream}

  # Check stream status every 1 minute
  @status_check_interval_seconds 60

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"stream_id" => stream_id, "unique_id" => unique_id, "brand_id" => brand_id}
      }) do
    Logger.info("Starting capture worker for stream #{stream_id}, @#{unique_id}")

    # Check if stream still exists and is in capturing state
    case Repo.get_by(Stream, id: stream_id, brand_id: brand_id) do
      nil ->
        Logger.warning("Stream #{stream_id} not found, aborting capture")
        :ok

      %Stream{status: :ended} ->
        Logger.info("Stream #{stream_id} has ended, aborting capture")
        :ok

      %Stream{status: :failed} ->
        Logger.info("Stream #{stream_id} has failed, aborting capture")
        :ok

      stream ->
        run_capture(stream, unique_id, brand_id)
    end
  end

  defp run_capture(stream, unique_id, brand_id) do
    stream_id = stream.id

    # IMPORTANT: Subscribe to bridge events BEFORE connecting to avoid losing events
    # The bridge starts sending events immediately after connect succeeds
    Phoenix.PubSub.subscribe(Pavoi.PubSub, "tiktok_live:bridge:events")

    # Now connect to bridge - any events will be queued in our mailbox
    case connect_via_bridge(unique_id) do
      {:ok, :connected} ->
        # Start the event handler now that we're connected
        start_event_handler_and_monitor(stream_id, unique_id, brand_id)

      {:error, reason} ->
        # Unsubscribe since we failed
        Phoenix.PubSub.unsubscribe(Pavoi.PubSub, "tiktok_live:bridge:events")
        Logger.error("Failed to connect to stream via bridge: #{inspect(reason)}")
        # Snooze and retry
        {:snooze, 60}
    end
  end

  defp connect_via_bridge(unique_id) do
    # Connect to the TikTok stream via Bridge HTTP API
    case BridgeClient.connect_stream(unique_id) do
      {:ok, _response} ->
        Logger.info("Connected to TikTok stream @#{unique_id} via bridge")
        {:ok, :connected}

      {:error, "Already connected to this stream"} ->
        # Bridge already has an active connection - this is fine, proceed to monitor
        Logger.info("Bridge already connected to @#{unique_id}, proceeding to monitor")
        {:ok, :connected}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_event_handler_and_monitor(stream_id, unique_id, brand_id) do
    event_handler_opts = [
      stream_id: stream_id,
      brand_id: brand_id,
      name: event_handler_name(stream_id)
    ]

    case EventHandler.start_link(event_handler_opts) do
      {:ok, event_handler_pid} ->
        monitor_capture(stream_id, unique_id, brand_id, event_handler_pid)

      {:error, {:already_started, pid}} ->
        Logger.info("Event handler already running for stream #{stream_id}")
        monitor_capture(stream_id, unique_id, brand_id, pid)

      {:error, reason} ->
        # Cleanup: unsubscribe and disconnect
        Phoenix.PubSub.unsubscribe(Pavoi.PubSub, "tiktok_live:bridge:events")
        disconnect_from_bridge(unique_id)
        Logger.error("Failed to start event handler: #{inspect(reason)}")
        {:snooze, 30}
    end
  end

  defp monitor_capture(stream_id, unique_id, brand_id, event_handler_pid) do
    # Monitor the event handler process
    event_handler_ref = Process.monitor(event_handler_pid)

    # Already subscribed to bridge events in run_capture

    result =
      capture_loop(
        stream_id,
        unique_id,
        brand_id,
        event_handler_pid,
        event_handler_ref
      )

    # Cleanup
    Process.demonitor(event_handler_ref, [:flush])
    Phoenix.PubSub.unsubscribe(Pavoi.PubSub, "tiktok_live:bridge:events")

    # Disconnect from bridge
    disconnect_from_bridge(unique_id)

    result
  end

  defp capture_loop(stream_id, unique_id, brand_id, event_handler_pid, event_handler_ref) do
    receive do
      # Bridge event for our stream - translate and forward to EventHandler
      {:tiktok_bridge_event, ^unique_id, event} ->
        handle_bridge_event(stream_id, brand_id, event)

        # Check for terminal events
        case event.type do
          :stream_ended ->
            Logger.info("Stream #{stream_id} ended")
            stop_event_handler(event_handler_pid)
            :ok

          :disconnected ->
            Logger.info("Stream #{stream_id} disconnected from bridge")
            stop_event_handler(event_handler_pid)
            :ok

          :error ->
            Logger.error("Bridge error for stream #{stream_id}: #{inspect(event[:error])}")
            stop_event_handler(event_handler_pid)
            # Snooze and retry
            {:snooze, 60}

          _ ->
            capture_loop(stream_id, unique_id, brand_id, event_handler_pid, event_handler_ref)
        end

      # Ignore events from other streams
      {:tiktok_bridge_event, _other_unique_id, _event} ->
        capture_loop(stream_id, unique_id, brand_id, event_handler_pid, event_handler_ref)

      # Event handler process died
      {:DOWN, ^event_handler_ref, :process, ^event_handler_pid, reason} ->
        Logger.warning("Event handler process died: #{inspect(reason)}")
        # Snooze and retry
        {:snooze, 30}

      # Ignore other messages
      _other ->
        capture_loop(stream_id, unique_id, brand_id, event_handler_pid, event_handler_ref)
    after
      @status_check_interval_seconds * 1000 ->
        # Check if stream is still valid
        case Repo.get_by(Stream, id: stream_id, brand_id: brand_id) do
          %Stream{status: :capturing} ->
            # Continue monitoring
            capture_loop(stream_id, unique_id, brand_id, event_handler_pid, event_handler_ref)

          _ ->
            Logger.info("Stream #{stream_id} no longer in capturing state")
            stop_event_handler(event_handler_pid)
            :ok
        end
    end
  end

  # Translate bridge event (keyed by unique_id) to the format EventHandler expects
  # (keyed by stream_id) and broadcast to the standard events topic
  defp handle_bridge_event(stream_id, brand_id, event) do
    Phoenix.PubSub.broadcast(
      Pavoi.PubSub,
      "tiktok_live:events:#{brand_id}",
      {:tiktok_live_event, stream_id, event}
    )
  end

  defp disconnect_from_bridge(unique_id) do
    case BridgeClient.disconnect_stream(unique_id) do
      {:ok, _} ->
        Logger.info("Disconnected from TikTok stream @#{unique_id}")

      {:error, reason} ->
        Logger.warning("Failed to disconnect from bridge: #{inspect(reason)}")
    end
  rescue
    _ -> :ok
  end

  defp stop_event_handler(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      EventHandler.stop(pid)
    end
  rescue
    _ -> :ok
  end

  defp stop_event_handler(_), do: :ok

  defp event_handler_name(stream_id) do
    {:via, Registry, {Pavoi.TiktokLive.Registry, {:event_handler, stream_id}}}
  end
end
