defmodule SocialObjects.Workers.GmvBackfillWorker do
  @moduledoc """
  Oban worker that backfills cumulative GMV tracking for existing creators.

  For creators with existing performance snapshots but no cumulative tracking:
  1. Orders snapshots by date ascending
  2. First snapshot's GMV = baseline (delta = gmv)
  3. For each subsequent snapshot: delta = max(0, current - previous)
  4. Sum all deltas = cumulative
  5. Updates creator record and snapshot delta fields

  ## Usage

  Run via:
      SocialObjects.Workers.GmvBackfillWorker.new(%{}) |> Oban.insert()

  Or run synchronously for testing:
      SocialObjects.Workers.GmvBackfillWorker.run_sync()
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing]]

  require Logger
  import Ecto.Query

  alias SocialObjects.Creators.BrandCreator
  alias SocialObjects.Creators.Creator
  alias SocialObjects.Creators.CreatorPerformanceSnapshot
  alias SocialObjects.Repo
  alias SocialObjects.Settings

  @batch_size 100

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    brand_id = resolve_brand_id(Map.get(args, "brand_id"))
    _ = broadcast(brand_id, {:gmv_backfill_started})

    try do
      :ok = run_backfill(brand_id)
      _ = if brand_id, do: Settings.update_gmv_backfill_last_run_at(brand_id)
      _ = broadcast(brand_id, {:gmv_backfill_completed})
      :ok
    rescue
      exception ->
        reason = Exception.message(exception)
        _ = broadcast(brand_id, {:gmv_backfill_failed, reason})
        {:error, reason}
    end
  end

  @doc """
  Run the backfill synchronously (useful for testing).
  """
  def run_sync do
    run_backfill(nil)
  end

  defp run_backfill(brand_id) do
    Logger.info(
      "[GmvBackfill] Starting cumulative GMV backfill for #{backfill_scope(brand_id)}..."
    )

    # Find creators with snapshots but no cumulative tracking
    creators_to_process = get_creators_needing_backfill(brand_id)

    Logger.info("[GmvBackfill] Found #{length(creators_to_process)} creators to process")

    stats =
      creators_to_process
      |> Enum.reduce(%{processed: 0, updated: 0, skipped: 0, errors: 0}, fn creator_id, acc ->
        case process_creator(creator_id) do
          :ok -> %{acc | processed: acc.processed + 1, updated: acc.updated + 1}
          :skipped -> %{acc | processed: acc.processed + 1, skipped: acc.skipped + 1}
          :error -> %{acc | processed: acc.processed + 1, errors: acc.errors + 1}
        end
      end)

    Logger.info("""
    [GmvBackfill] Completed
      - Processed: #{stats.processed}
      - Updated: #{stats.updated}
      - Skipped: #{stats.skipped}
      - Errors: #{stats.errors}
    """)

    :ok
  end

  defp get_creators_needing_backfill(nil) do
    # Find creators who:
    # 1. Have no gmv_tracking_started_at (no cumulative tracking)
    # 2. Have at least one performance snapshot with GMV data
    from(c in Creator,
      as: :creator,
      where: is_nil(c.gmv_tracking_started_at),
      where:
        exists(
          from(s in CreatorPerformanceSnapshot,
            where: s.creator_id == parent_as(:creator).id,
            where:
              not is_nil(s.gmv_cents) or not is_nil(s.video_gmv_cents) or
                not is_nil(s.live_gmv_cents)
          )
        ),
      select: c.id,
      limit: ^@batch_size
    )
    |> Repo.all()
  end

  defp get_creators_needing_backfill(brand_id) do
    from(c in Creator,
      as: :creator,
      join: bc in BrandCreator,
      on: bc.creator_id == c.id,
      where: bc.brand_id == ^brand_id,
      where: is_nil(c.gmv_tracking_started_at),
      where:
        exists(
          from(s in CreatorPerformanceSnapshot,
            where: s.creator_id == parent_as(:creator).id,
            where:
              not is_nil(s.gmv_cents) or not is_nil(s.video_gmv_cents) or
                not is_nil(s.live_gmv_cents)
          )
        ),
      distinct: true,
      select: c.id,
      limit: ^@batch_size
    )
    |> Repo.all()
  end

  defp process_creator(creator_id) do
    # Get all snapshots for this creator ordered by date
    snapshots =
      from(s in CreatorPerformanceSnapshot,
        where: s.creator_id == ^creator_id,
        where: s.source == "tiktok_marketplace",
        order_by: [asc: s.snapshot_date],
        select: %{
          id: s.id,
          snapshot_date: s.snapshot_date,
          gmv_cents: s.gmv_cents,
          video_gmv_cents: s.video_gmv_cents,
          live_gmv_cents: s.live_gmv_cents
        }
      )
      |> Repo.all()

    case snapshots do
      [] ->
        :skipped

      [first | rest] ->
        # First snapshot establishes baseline
        first_date = first.snapshot_date

        # Calculate cumulative by summing deltas
        {cumulative, snapshot_updates} = calculate_cumulative_from_snapshots([first | rest])

        # Update creator with cumulative values and tracking start date
        update_creator_cumulative(creator_id, cumulative, first_date)

        # Update snapshots with delta values
        update_snapshot_deltas(snapshot_updates)

        :ok
    end
  rescue
    e ->
      Logger.error(
        "[GmvBackfill] Error processing creator #{creator_id}: #{Exception.message(e)}"
      )

      :error
  end

  defp calculate_cumulative_from_snapshots([first | rest]) do
    # First snapshot: delta = full GMV value (baseline)
    first_delta = %{
      id: first.id,
      gmv_delta_cents: first.gmv_cents || 0,
      video_gmv_delta_cents: first.video_gmv_cents || 0,
      live_gmv_delta_cents: first.live_gmv_cents || 0
    }

    # Process subsequent snapshots
    {cumulative, updates} =
      rest
      |> Enum.reduce(
        {
          # Initial cumulative (from first snapshot)
          %{
            gmv: first.gmv_cents || 0,
            video_gmv: first.video_gmv_cents || 0,
            live_gmv: first.live_gmv_cents || 0
          },
          # Previous values for delta calculation
          %{
            gmv: first.gmv_cents,
            video_gmv: first.video_gmv_cents,
            live_gmv: first.live_gmv_cents
          },
          # Accumulated snapshot updates
          [first_delta]
        },
        fn snapshot, {cumulative, previous, updates} ->
          # Calculate deltas (max 0, current - previous)
          gmv_delta = calculate_delta(snapshot.gmv_cents, previous.gmv)
          video_gmv_delta = calculate_delta(snapshot.video_gmv_cents, previous.video_gmv)
          live_gmv_delta = calculate_delta(snapshot.live_gmv_cents, previous.live_gmv)

          # Update cumulative
          new_cumulative = %{
            gmv: cumulative.gmv + gmv_delta,
            video_gmv: cumulative.video_gmv + video_gmv_delta,
            live_gmv: cumulative.live_gmv + live_gmv_delta
          }

          # Track previous values for next iteration
          new_previous = %{
            gmv: snapshot.gmv_cents,
            video_gmv: snapshot.video_gmv_cents,
            live_gmv: snapshot.live_gmv_cents
          }

          # Build snapshot update
          update = %{
            id: snapshot.id,
            gmv_delta_cents: gmv_delta,
            video_gmv_delta_cents: video_gmv_delta,
            live_gmv_delta_cents: live_gmv_delta
          }

          {new_cumulative, new_previous, [update | updates]}
        end
      )

    # Return final cumulative and all snapshot updates
    {cumulative, Enum.reverse(updates)}
  end

  defp calculate_delta(nil, _previous), do: 0
  defp calculate_delta(_current, nil), do: 0
  defp calculate_delta(current, previous), do: max(0, current - previous)

  defp update_creator_cumulative(creator_id, cumulative, tracking_start_date) do
    from(c in Creator, where: c.id == ^creator_id)
    |> Repo.update_all(
      set: [
        cumulative_gmv_cents: cumulative.gmv,
        cumulative_video_gmv_cents: cumulative.video_gmv,
        cumulative_live_gmv_cents: cumulative.live_gmv,
        gmv_tracking_started_at: tracking_start_date
      ]
    )
  end

  defp update_snapshot_deltas(snapshot_updates) do
    Enum.each(snapshot_updates, fn update ->
      from(s in CreatorPerformanceSnapshot, where: s.id == ^update.id)
      |> Repo.update_all(
        set: [
          gmv_delta_cents: update.gmv_delta_cents,
          video_gmv_delta_cents: update.video_gmv_delta_cents,
          live_gmv_delta_cents: update.live_gmv_delta_cents
        ]
      )
    end)
  end

  defp backfill_scope(nil), do: "all brands"
  defp backfill_scope(brand_id), do: "brand #{brand_id}"

  defp resolve_brand_id(nil), do: nil
  defp resolve_brand_id(brand_id) when is_integer(brand_id), do: brand_id
  defp resolve_brand_id(brand_id) when is_binary(brand_id), do: String.to_integer(brand_id)

  defp broadcast(brand_id, message) do
    if brand_id do
      Phoenix.PubSub.broadcast(
        SocialObjects.PubSub,
        "gmv_backfill:sync:#{brand_id}",
        message
      )
    end
  end
end
