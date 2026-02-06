defmodule Pavoi.Workers.TiktokLiveMonitorWorker do
  @moduledoc """
  Oban worker that monitors TikTok accounts for live stream status.

  Runs on a cron schedule (every 2 minutes) to check if monitored accounts
  are currently live streaming. When a live stream is detected:

  1. Creates a new stream record in the database
  2. Enqueues a TiktokLiveStreamWorker to start capturing events

  ## Configuration

  The accounts to monitor are configured in the application config:

      config :pavoi, :tiktok_live_monitor,
        accounts: ["brand_handle"]

  """

  use Oban.Worker,
    queue: :tiktok,
    max_attempts: 1,
    unique: [period: 60, states: [:available, :scheduled, :executing]]

  require Logger

  alias Pavoi.Repo
  alias Pavoi.Settings
  alias Pavoi.TiktokLive.{Client, Stream}
  alias Pavoi.Workers.{StreamReportWorker, TiktokLiveStreamWorker}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    source = Map.get(args, "source", "cron")

    case resolve_brand_id(Map.get(args, "brand_id")) do
      {:ok, brand_id} ->
        accounts = monitored_accounts(brand_id)

        Logger.debug("Checking live status for accounts: #{inspect(accounts)}")

        Enum.each(accounts, &check_account(&1, brand_id))

        Settings.update_tiktok_live_last_scan_at(brand_id)

        Phoenix.PubSub.broadcast(
          Pavoi.PubSub,
          "tiktok_live:scan:#{brand_id}",
          {:scan_completed, source}
        )

        :ok

      {:error, reason} ->
        Logger.error("[TiktokLiveMonitor] Failed to resolve brand_id: #{inspect(reason)}")
        {:discard, reason}
    end
  end

  defp check_account(unique_id, brand_id) do
    Logger.debug("Checking if @#{unique_id} is live")

    case Client.fetch_room_info(unique_id) do
      {:ok, %{is_live: true, room_id: room_id} = room_info} ->
        handle_live_detected(brand_id, unique_id, room_id, room_info)

      {:ok, %{is_live: false}} ->
        Logger.debug("@#{unique_id} is not live")
        handle_not_live(brand_id, unique_id)

      {:error, :room_id_not_found} ->
        Logger.debug("@#{unique_id} is not live (no room found)")
        handle_not_live(brand_id, unique_id)

      {:error, reason} ->
        Logger.warning("Failed to check live status for @#{unique_id}: #{inspect(reason)}")
    end
  end

  defp handle_live_detected(brand_id, unique_id, room_id, room_info) do
    Logger.info("@#{unique_id} is LIVE in room #{room_id}")

    # Check if we're already capturing this stream
    case get_active_stream(brand_id, room_id) do
      nil ->
        handle_no_active_stream(brand_id, unique_id, room_id, room_info)

      stream ->
        # Check if the capture is actually healthy (receiving events)
        if capture_healthy?(stream) do
          Logger.debug("Already capturing stream #{stream.id} for room #{room_id}")
        else
          Logger.warning("Stream #{stream.id} capture appears stale, restarting worker")
          restart_stale_capture(stream, unique_id, brand_id)
        end
    end
  end

  defp handle_no_active_stream(brand_id, unique_id, room_id, room_info) do
    # Check if there's a recently-ended stream for the same room we can resume
    # This handles app restarts/deployments during a live broadcast
    case get_resumable_stream(brand_id, room_id) do
      nil ->
        # Check if there's ANY recent stream for this room_id that might still be
        # part of the same broadcast (handles long gaps from disconnects/reconnects)
        case get_any_recent_stream_for_room(brand_id, room_id) do
          nil ->
            start_capture(brand_id, unique_id, room_id, room_info)

          stream ->
            Logger.info(
              "Found recent stream #{stream.id} for room #{room_id}, resuming instead of creating new"
            )

            resume_capture(stream, unique_id, brand_id)
        end

      stream ->
        resume_capture(stream, unique_id, brand_id)
    end
  end

  defp handle_not_live(brand_id, unique_id) do
    # Check if we have any capturing streams for this account that should be marked ended
    import Ecto.Query

    capturing_streams =
      from(s in Stream,
        where: s.brand_id == ^brand_id and s.unique_id == ^unique_id and s.status == :capturing
      )
      |> Repo.all()

    Enum.each(capturing_streams, fn stream ->
      Logger.info("Marking stream #{stream.id} as ended (account no longer live)")

      case Pavoi.TiktokLive.mark_stream_ended(brand_id, stream.id) do
        {:ok, :ended} ->
          # Enqueue Slack report job for the completed stream
          # Delay 10 minutes to allow monitor to detect if stream is actually still live
          # (handles false end detection during deploys/API blips)
          Logger.info("Enqueueing stream report for stream #{stream.id} (scheduled in 10 min)")

          %{stream_id: stream.id, brand_id: brand_id}
          |> StreamReportWorker.new(schedule_in: 600)
          |> Oban.insert()

        {:error, :already_ended} ->
          Logger.debug("Stream #{stream.id} already ended, skipping report enqueue")
      end
    end)
  end

  defp start_capture(brand_id, unique_id, room_id, room_info) do
    # Create stream record
    stream_attrs = %{
      brand_id: brand_id,
      room_id: room_id,
      unique_id: unique_id,
      title: room_info[:title],
      started_at: DateTime.utc_now() |> DateTime.truncate(:second),
      status: :capturing,
      viewer_count_peak: room_info[:viewer_count] || 0,
      raw_metadata: Map.drop(room_info, [:is_live])
    }

    case %Stream{brand_id: brand_id} |> Stream.changeset(stream_attrs) |> Repo.insert() do
      {:ok, stream} ->
        Logger.info("Created stream record #{stream.id} for @#{unique_id}")

        # Enqueue the stream worker to handle the actual capture
        %{stream_id: stream.id, unique_id: unique_id, brand_id: brand_id}
        |> TiktokLiveStreamWorker.new()
        |> Oban.insert()

        # Broadcast that capture has started
        Phoenix.PubSub.broadcast(
          Pavoi.PubSub,
          "tiktok_live:monitor:#{brand_id}",
          {:capture_started, stream}
        )

      {:error, %{errors: [room_id: {"has already been taken", _}]}} ->
        # Race condition: another process created a capturing stream for this room
        # This is expected and handled by the unique index
        Logger.info("Stream already being captured for room #{room_id} (caught by unique index)")

      {:error, changeset} ->
        Logger.error("Failed to create stream record: #{inspect(changeset.errors)}")
    end
  end

  defp get_active_stream(brand_id, room_id) do
    import Ecto.Query

    from(s in Stream,
      where: s.brand_id == ^brand_id and s.room_id == ^room_id and s.status == :capturing,
      limit: 1
    )
    |> Repo.one()
  end

  # Find a stream that ended recently and can be resumed
  # This handles app restarts/deployments - if a stream with the same room_id
  # ended within the last 10 minutes, it's likely the same broadcast
  defp get_resumable_stream(brand_id, room_id) do
    import Ecto.Query

    cutoff = DateTime.utc_now() |> DateTime.add(-10, :minute)

    from(s in Stream,
      where: s.brand_id == ^brand_id and s.room_id == ^room_id and s.status == :ended,
      where: s.ended_at > ^cutoff,
      order_by: [desc: s.ended_at],
      limit: 1
    )
    |> Repo.one()
  end

  # Find ANY stream with the same room_id that started within the last 6 hours
  # This is a broader check than get_resumable_stream and handles the case where
  # a stream was marked ended > 10 minutes ago but the TikTok broadcast is still
  # ongoing (e.g., after a long disconnect/reconnect gap)
  defp get_any_recent_stream_for_room(brand_id, room_id) do
    import Ecto.Query

    cutoff = DateTime.utc_now() |> DateTime.add(-6, :hour)

    from(s in Stream,
      where: s.brand_id == ^brand_id and s.room_id == ^room_id and s.started_at > ^cutoff,
      order_by: [desc: s.started_at],
      limit: 1
    )
    |> Repo.one()
  end

  # Resume a previously-ended stream by setting it back to capturing
  defp resume_capture(stream, unique_id, brand_id) do
    Logger.info("Resuming stream #{stream.id} for @#{unique_id} (same room_id, ended recently)")

    case stream
         |> Stream.changeset(%{status: :capturing, ended_at: nil})
         |> Repo.update() do
      {:ok, updated_stream} ->
        # Enqueue the stream worker to resume capture
        %{stream_id: updated_stream.id, unique_id: unique_id, brand_id: brand_id}
        |> TiktokLiveStreamWorker.new()
        |> Oban.insert()

        # Broadcast that capture has resumed
        Phoenix.PubSub.broadcast(
          Pavoi.PubSub,
          "tiktok_live:monitor:#{brand_id}",
          {:capture_resumed, updated_stream}
        )

        Logger.info("Successfully resumed stream #{stream.id}")

      {:error, changeset} ->
        Logger.error("Failed to resume stream #{stream.id}: #{inspect(changeset.errors)}")
    end
  end

  # Check if a capture is receiving events (stats updated within last 3 minutes)
  # Stats are saved every 30s, so 3 min = 6 missed saves = definitely stale
  # Exception: streams that just started (< 2 min old) are considered healthy
  # since they may not have saved their first stat yet
  defp capture_healthy?(stream) do
    import Ecto.Query
    alias Pavoi.TiktokLive.StreamStat

    # New streams (< 2 min old) are given grace period
    stream_age_seconds = DateTime.diff(DateTime.utc_now(), stream.started_at)

    if stream_age_seconds < 120 do
      # Stream just started, consider healthy
      true
    else
      cutoff = DateTime.utc_now() |> DateTime.add(-3, :minute)

      recent_stat =
        from(s in StreamStat,
          where:
            s.brand_id == ^stream.brand_id and s.stream_id == ^stream.id and
              s.recorded_at > ^cutoff,
          limit: 1
        )
        |> Repo.one()

      recent_stat != nil
    end
  end

  # Restart a stale capture by re-enqueuing the worker
  defp restart_stale_capture(stream, unique_id, brand_id) do
    # Cancel any existing scheduled/available jobs for this stream
    import Ecto.Query

    Oban.Job
    |> where([j], j.worker == "Pavoi.Workers.TiktokLiveStreamWorker")
    |> where([j], j.state in ["available", "scheduled"])
    |> where([j], fragment("?->>'stream_id' = ?", j.args, ^to_string(stream.id)))
    |> Repo.update_all(set: [state: "cancelled", cancelled_at: DateTime.utc_now()])

    # Enqueue a fresh worker
    %{stream_id: stream.id, unique_id: unique_id, brand_id: brand_id}
    |> TiktokLiveStreamWorker.new()
    |> Oban.insert()

    Logger.info("Restarted capture worker for stream #{stream.id}")
  end

  defp monitored_accounts(brand_id) do
    Settings.get_tiktok_live_accounts(brand_id)
  end

  defp normalize_brand_id(brand_id) when is_integer(brand_id), do: brand_id

  defp normalize_brand_id(brand_id) when is_binary(brand_id) do
    String.to_integer(brand_id)
  end

  defp resolve_brand_id(nil) do
    {:error, :brand_id_required}
  end

  defp resolve_brand_id(brand_id), do: {:ok, normalize_brand_id(brand_id)}
end
