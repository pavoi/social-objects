defmodule Pavoi.TiktokLive.BridgeClient do
  @moduledoc """
  WebSocket client for the TikTok Bridge service.

  Connects to the Node.js bridge service via WebSocket to receive TikTok Live events.
  The bridge handles all TikTok protocol complexity; we just receive parsed events.

  ## Architecture

      Elixir App
          |
          | WebSocket (/events)
          v
      TikTok Bridge (Node.js)
          |
          | TikTok Protocol
          v
      TikTok Live Servers

  ## Usage

      {:ok, pid} = BridgeClient.start_link()

      # Connect to a TikTok stream (via HTTP API)
      BridgeClient.connect_stream("pavoi")

      # Events are broadcast via PubSub to "tiktok_live:bridge:events"
  """

  use WebSockex

  require Logger

  @reconnect_delay_ms 3_000
  @max_reconnect_attempts 10
  @heartbeat_interval_ms 15_000
  # If no events received for this long, consider connection stale
  @stale_connection_threshold_ms 120_000

  defmodule State do
    @moduledoc false
    defstruct [
      :bridge_url,
      :reconnect_attempts,
      :connected_at,
      :heartbeat_ref,
      :last_event_at
    ]
  end

  @doc """
  Starts the bridge client WebSocket connection.

  ## Options

  - `:bridge_url` - WebSocket URL of the bridge service. Defaults to env config.
  - `:name` - Process name for registration. Defaults to `__MODULE__`.

  Returns `:ignore` if bridge URL is not configured (allows safe supervision).
  """
  def start_link(opts \\ []) do
    bridge_url = Keyword.get(opts, :bridge_url, bridge_ws_url())
    name = Keyword.get(opts, :name, __MODULE__)

    if is_nil(bridge_url) or bridge_url == "" do
      Logger.warning("TikTok Bridge URL not configured, skipping BridgeClient")
      :ignore
    else
      Logger.info("Starting TikTok Bridge client, connecting to #{bridge_url}")

      state = %State{
        bridge_url: bridge_url,
        reconnect_attempts: 0
      }

      # Start with async connection to avoid blocking supervisor
      # handle_initial_conn_failure allows the process to start even if connection fails
      ws_opts = [name: name, handle_initial_conn_failure: true, async: true]

      case WebSockex.start_link(bridge_url, __MODULE__, state, ws_opts) do
        {:ok, pid} ->
          {:ok, pid}

        {:error, reason} ->
          Logger.warning("TikTok Bridge connection failed: #{inspect(reason)}, will retry")
          # Return :ignore to not crash the supervisor - bridge is optional
          :ignore
      end
    end
  end

  @doc """
  Returns the child spec for supervision tree.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @doc """
  Connect to a TikTok Live stream via the bridge HTTP API.
  This is independent of the WebSocket connection.
  """
  def connect_stream(unique_id) do
    http_url = bridge_http_url()

    case Req.post("#{http_url}/connect",
           json: %{uniqueId: unique_id},
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: _status, body: body}} ->
        {:error, body["error"] || "Connection failed"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Disconnect from a TikTok Live stream.
  """
  def disconnect_stream(unique_id) do
    http_url = bridge_http_url()

    case Req.post("#{http_url}/disconnect",
           json: %{uniqueId: unique_id},
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: _status, body: body}} ->
        {:error, body["error"] || "Disconnect failed"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get bridge status including active connections.
  """
  def status do
    http_url = bridge_http_url()

    case Req.get("#{http_url}/status", receive_timeout: 5_000) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Health check for the bridge service.
  """
  def health do
    http_url = bridge_http_url()

    case Req.get("#{http_url}/health", receive_timeout: 5_000) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # WebSockex callbacks

  @impl WebSockex
  def handle_connect(_conn, state) do
    Logger.info("Connected to TikTok Bridge WebSocket")

    # Cancel any existing heartbeat timer
    cancel_heartbeat(state.heartbeat_ref)

    # Start heartbeat timer
    heartbeat_ref = Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)

    new_state = %{
      state
      | connected_at: DateTime.utc_now(),
        reconnect_attempts: 0,
        heartbeat_ref: heartbeat_ref,
        last_event_at: DateTime.utc_now()
    }

    {:ok, new_state}
  end

  @impl WebSockex
  def handle_frame({:text, data}, state) do
    case Jason.decode(data) do
      {:ok, event} ->
        handle_bridge_event(event)
        {:ok, %{state | last_event_at: DateTime.utc_now()}}

      {:error, reason} ->
        Logger.warning("Failed to parse bridge message: #{inspect(reason)}")
        {:ok, state}
    end
  end

  @impl WebSockex
  def handle_frame(_frame, state) do
    {:ok, %{state | last_event_at: DateTime.utc_now()}}
  end

  @impl WebSockex
  def handle_info(:heartbeat, state) do
    # Check for stale connection (no events received recently)
    if state.last_event_at do
      ms_since_last_event = DateTime.diff(DateTime.utc_now(), state.last_event_at, :millisecond)

      if ms_since_last_event > @stale_connection_threshold_ms do
        Logger.warning(
          "No events received for #{div(ms_since_last_event, 1000)}s, forcing reconnect"
        )

        # Close connection to trigger reconnect
        {:close, {1000, "Stale connection"}, state}
      else
        # Send a ping frame to keep connection alive
        heartbeat_ref = Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)
        {:reply, {:ping, ""}, %{state | heartbeat_ref: heartbeat_ref}}
      end
    else
      # No events yet, just send ping
      heartbeat_ref = Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)
      {:reply, {:ping, ""}, %{state | heartbeat_ref: heartbeat_ref}}
    end
  end

  @impl WebSockex
  def handle_info(_msg, state) do
    {:ok, state}
  end

  @impl WebSockex
  def handle_disconnect(disconnect_map, state) do
    cancel_heartbeat(state.heartbeat_ref)

    reason = Map.get(disconnect_map, :reason)
    Logger.warning("Disconnected from TikTok Bridge: #{inspect(reason)}")

    if state.reconnect_attempts < @max_reconnect_attempts do
      Logger.info(
        "Attempting reconnection #{state.reconnect_attempts + 1}/#{@max_reconnect_attempts}"
      )

      Process.sleep(@reconnect_delay_ms)

      {:reconnect, %{state | reconnect_attempts: state.reconnect_attempts + 1, heartbeat_ref: nil}}
    else
      # Crash to trigger supervisor restart with fresh state
      Logger.error("Max reconnection attempts reached, crashing to trigger supervisor restart")
      {:close, {1000, "Max reconnection attempts reached"}, state}
    end
  end

  @impl WebSockex
  def terminate(reason, state) do
    cancel_heartbeat(state.heartbeat_ref)
    Logger.info("TikTok Bridge client terminated: #{inspect(reason)}")
    :ok
  end

  # Private functions

  defp handle_bridge_event(%{"type" => "status", "connections" => connections}) do
    Logger.debug("Bridge status: #{length(connections)} active connections")
  end

  defp handle_bridge_event(%{"type" => "connected", "uniqueId" => unique_id} = event) do
    Logger.info("Stream connected: @#{unique_id}")
    broadcast_event(unique_id, %{type: :connected, raw: event})
  end

  defp handle_bridge_event(%{"type" => "disconnected", "uniqueId" => unique_id}) do
    Logger.info("Stream disconnected: @#{unique_id}")
    broadcast_event(unique_id, %{type: :disconnected})
  end

  defp handle_bridge_event(%{"type" => "error", "uniqueId" => unique_id, "error" => error}) do
    Logger.error("Stream error for @#{unique_id}: #{error}")
    broadcast_event(unique_id, %{type: :error, error: error})
  end

  defp handle_bridge_event(%{"type" => "chat", "uniqueId" => unique_id, "data" => data}) do
    broadcast_event(unique_id, %{
      type: :comment,
      msg_id: data["msgId"],
      user_id: to_string(data["userId"]),
      username: data["uniqueId"],
      nickname: data["nickname"],
      content: data["comment"],
      timestamp: parse_timestamp(data["createTime"]),
      raw: data
    })
  end

  defp handle_bridge_event(%{"type" => "gift", "uniqueId" => unique_id, "data" => data}) do
    broadcast_event(unique_id, %{
      type: :gift,
      user_id: to_string(data["userId"]),
      username: data["uniqueId"],
      nickname: data["nickname"],
      gift_id: data["giftId"],
      gift_name: data["giftName"],
      diamond_count: data["diamondCount"],
      repeat_count: data["repeatCount"],
      repeat_end: data["repeatEnd"],
      timestamp: parse_timestamp(data["createTime"]),
      raw: data
    })
  end

  defp handle_bridge_event(%{"type" => "like", "uniqueId" => unique_id, "data" => data}) do
    broadcast_event(unique_id, %{
      type: :like,
      user_id: to_string(data["userId"]),
      username: data["uniqueId"],
      nickname: data["nickname"],
      count: data["likeCount"],
      total_count: data["totalLikeCount"],
      timestamp: DateTime.utc_now() |> DateTime.truncate(:second),
      raw: data
    })
  end

  defp handle_bridge_event(%{"type" => "member", "uniqueId" => unique_id, "data" => data}) do
    broadcast_event(unique_id, %{
      type: :join,
      user_id: to_string(data["userId"]),
      username: data["uniqueId"],
      nickname: data["nickname"],
      timestamp: DateTime.utc_now() |> DateTime.truncate(:second),
      raw: data
    })
  end

  defp handle_bridge_event(%{"type" => "roomUser", "uniqueId" => unique_id, "data" => data}) do
    broadcast_event(unique_id, %{
      type: :viewer_count,
      viewer_count: data["viewerCount"],
      timestamp: DateTime.utc_now() |> DateTime.truncate(:second),
      raw: data
    })
  end

  defp handle_bridge_event(%{"type" => "social", "uniqueId" => unique_id, "data" => data}) do
    action_type =
      case data["displayType"] do
        "follow" -> :follow
        "share" -> :share
        _ -> :social
      end

    broadcast_event(unique_id, %{
      type: action_type,
      user_id: to_string(data["userId"]),
      username: data["uniqueId"],
      nickname: data["nickname"],
      timestamp: DateTime.utc_now() |> DateTime.truncate(:second),
      raw: data
    })
  end

  defp handle_bridge_event(%{"type" => "streamEnd", "uniqueId" => unique_id}) do
    Logger.info("Stream ended: @#{unique_id}")
    broadcast_event(unique_id, %{type: :stream_ended})
  end

  defp handle_bridge_event(event) do
    Logger.debug("Unknown bridge event: #{inspect(event)}")
  end

  defp broadcast_event(unique_id, event) do
    # Broadcast to the bridge events topic for workers to translate and forward
    Phoenix.PubSub.broadcast(
      Pavoi.PubSub,
      "tiktok_live:bridge:events",
      {:tiktok_bridge_event, unique_id, event}
    )
  end

  defp bridge_ws_url do
    base = Application.get_env(:pavoi, :tiktok_bridge_url)

    if is_nil(base) or base == "" do
      nil
    else
      base
      |> String.replace(~r{^http://}, "ws://")
      |> String.replace(~r{^https://}, "wss://")
      |> Kernel.<>("/events")
    end
  end

  defp bridge_http_url do
    Application.get_env(:pavoi, :tiktok_bridge_url, "http://localhost:8080")
  end

  defp parse_timestamp(nil), do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp parse_timestamp(ts) when is_integer(ts) do
    ts = if ts > 10_000_000_000, do: div(ts, 1000), else: ts

    case DateTime.from_unix(ts) do
      {:ok, dt} -> DateTime.truncate(dt, :second)
      _ -> DateTime.utc_now() |> DateTime.truncate(:second)
    end
  end

  defp parse_timestamp(_), do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp cancel_heartbeat(nil), do: :ok
  defp cancel_heartbeat(ref), do: Process.cancel_timer(ref)
end
