defmodule Pavoi.TiktokLive.StreamReconciler do
  @moduledoc """
  Reconciles stream state on application startup.

  Handles two scenarios:
  1. Orphaned "capturing" streams - streams marked as capturing but with no active worker
  2. Recently ended streams - streams that ended but are still live on TikTok

  For each case, if the stream is still live with the same room_id, restart capture.
  """

  require Logger

  alias Pavoi.Repo
  alias Pavoi.TiktokLive.{Client, Stream}
  alias Pavoi.Workers.TiktokLiveStreamWorker

  import Ecto.Query

  # How far back to look for recently ended streams that might still be live
  @recovery_window_hours 2

  @doc """
  Runs stream reconciliation. Should be called on application startup.

  Returns the number of streams that were reconciled.
  """
  def run do
    # First, cancel any stale scheduled/executing jobs for TikTok streams
    # These would have been left over from a previous deploy
    cancelled = cancel_stale_stream_jobs()

    if cancelled > 0 do
      Logger.info("Stream reconciliation: cancelled #{cancelled} stale Oban jobs")
    end

    # Handle orphaned capturing streams
    orphaned_count = reconcile_orphaned_capturing_streams()

    # Also check recently ended streams that might still be live
    recovered_count = recover_recently_ended_streams()

    cancelled + orphaned_count + recovered_count
  end

  defp reconcile_orphaned_capturing_streams do
    orphaned_streams = find_orphaned_capturing_streams()

    if Enum.empty?(orphaned_streams) do
      Logger.debug("Stream reconciliation: no orphaned capturing streams found")
      0
    else
      Logger.info("Stream reconciliation: found #{length(orphaned_streams)} orphaned streams")

      Enum.each(orphaned_streams, fn stream ->
        reconcile_orphaned_stream(stream)
      end)

      length(orphaned_streams)
    end
  end

  defp recover_recently_ended_streams do
    recently_ended = find_recently_ended_streams()

    if Enum.empty?(recently_ended) do
      Logger.debug("Stream reconciliation: no recently ended streams to check")
      0
    else
      Logger.info(
        "Stream reconciliation: checking #{length(recently_ended)} recently ended streams"
      )

      recovered =
        Enum.count(recently_ended, fn stream ->
          check_and_recover_ended_stream(stream)
        end)

      if recovered > 0 do
        Logger.info("Stream reconciliation: recovered #{recovered} streams that were still live")
      end

      recovered
    end
  end

  # Check if stream is still live and restart capture, otherwise mark as ended
  defp reconcile_orphaned_stream(stream) do
    case Client.fetch_room_info(stream.unique_id) do
      {:ok, %{is_live: true, room_id: room_id}} when room_id == stream.room_id ->
        # Stream is still live with same room_id, restart capture
        Logger.info(
          "Stream #{stream.id} (@#{stream.unique_id}) is still live, restarting capture"
        )

        restart_capture(stream)

      {:ok, %{is_live: true}} ->
        # Live but different room_id means this is a new stream
        Logger.info(
          "Stream #{stream.id} (@#{stream.unique_id}) has new room_id, marking as ended"
        )

        mark_stream_ended(stream)

      _ ->
        # Not live or error checking, mark as ended
        Logger.info(
          "Stream #{stream.id} (@#{stream.unique_id}) is no longer live, marking as ended"
        )

        mark_stream_ended(stream)
    end
  end

  defp restart_capture(stream) do
    # First, disconnect from the bridge to clear any stale connection state
    # The bridge may still think it's connected from before the restart
    case Pavoi.TiktokLive.BridgeClient.disconnect_stream(stream.unique_id) do
      {:ok, _} ->
        Logger.debug("Disconnected stale bridge connection for @#{stream.unique_id}")

      {:error, reason} ->
        Logger.debug(
          "No existing bridge connection for @#{stream.unique_id} (#{inspect(reason)})"
        )
    end

    # Now enqueue a fresh worker to establish a new connection
    %{stream_id: stream.id, unique_id: stream.unique_id}
    |> TiktokLiveStreamWorker.new()
    |> Oban.insert()
  end

  @doc """
  Cancels stale Oban jobs for stream capture that were left over from a deploy.
  Jobs in 'available', 'scheduled' or 'executing' state are considered stale on startup.
  After restart, Oban may rescue 'executing' jobs as 'available', so we must cancel those too.
  """
  def cancel_stale_stream_jobs do
    query = """
    UPDATE oban_jobs
    SET state = 'cancelled', cancelled_at = NOW()
    WHERE worker = 'Pavoi.Workers.TiktokLiveStreamWorker'
      AND state IN ('available', 'scheduled', 'executing')
    RETURNING id
    """

    case Repo.query(query) do
      {:ok, %{num_rows: count}} -> count
      {:error, _} -> 0
    end
  end

  @doc """
  Finds streams marked as "capturing" that don't have an active Oban job.
  """
  def find_orphaned_capturing_streams do
    # Get all capturing streams
    capturing_streams =
      Stream
      |> where([s], s.status == :capturing)
      |> Repo.all()

    # Get active Oban job stream IDs
    active_job_stream_ids = get_active_job_stream_ids()

    # Filter to streams without active jobs
    Enum.reject(capturing_streams, fn stream ->
      stream.id in active_job_stream_ids
    end)
  end

  defp get_active_job_stream_ids do
    # Query Oban jobs for our worker that are in active states
    query = """
    SELECT args->>'stream_id' as stream_id
    FROM oban_jobs
    WHERE worker = 'Pavoi.Workers.TiktokLiveStreamWorker'
      AND state IN ('available', 'scheduled', 'executing', 'retryable')
    """

    case Repo.query(query) do
      {:ok, %{rows: rows}} ->
        rows
        |> Enum.map(fn [id] -> String.to_integer(id) end)
        |> MapSet.new()

      {:error, _} ->
        MapSet.new()
    end
  end

  defp mark_stream_ended(stream) do
    Logger.info("Marking orphaned stream #{stream.id} (@#{stream.unique_id}) as ended")

    stream
    |> Stream.changeset(%{
      status: :ended,
      ended_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
  end

  @doc """
  Finds streams that ended recently and might still be live on TikTok.
  Only checks streams that ended within the recovery window.
  """
  def find_recently_ended_streams do
    cutoff = DateTime.utc_now() |> DateTime.add(-@recovery_window_hours, :hour)

    Stream
    |> where([s], s.status == :ended)
    |> where([s], s.ended_at >= ^cutoff)
    |> order_by([s], desc: s.ended_at)
    |> Repo.all()
  end

  # Check if an ended stream is still live and recover it if so
  defp check_and_recover_ended_stream(stream) do
    case Client.fetch_room_info(stream.unique_id) do
      {:ok, %{is_live: true, room_id: room_id}} when room_id == stream.room_id ->
        # Stream is still live with same room_id - this shouldn't have ended!
        Logger.info(
          "Stream #{stream.id} (@#{stream.unique_id}) is still live with same room_id, recovering"
        )

        recover_stream(stream)
        true

      {:ok, %{is_live: true, room_id: new_room_id}} ->
        # Different room_id means it's a new stream - don't recover old one
        Logger.debug(
          "Stream #{stream.id} (@#{stream.unique_id}) has new room_id #{new_room_id}, not recovering"
        )

        false

      _ ->
        # Not live or error - stream correctly ended
        false
    end
  end

  defp recover_stream(stream) do
    # First disconnect any stale bridge connection
    case Pavoi.TiktokLive.BridgeClient.disconnect_stream(stream.unique_id) do
      {:ok, _} ->
        Logger.debug("Disconnected stale bridge connection for @#{stream.unique_id}")

      {:error, _reason} ->
        :ok
    end

    # Update stream back to capturing status
    {:ok, stream} =
      stream
      |> Stream.changeset(%{status: :capturing, ended_at: nil})
      |> Repo.update()

    # Enqueue capture worker
    %{stream_id: stream.id, unique_id: stream.unique_id}
    |> TiktokLiveStreamWorker.new()
    |> Oban.insert()
  end
end
