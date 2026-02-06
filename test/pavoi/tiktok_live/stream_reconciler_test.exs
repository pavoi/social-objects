defmodule Pavoi.TiktokLive.StreamReconcilerTest do
  @moduledoc """
  Tests for stream reconciliation and recovery behavior.

  These tests verify:
  - Pending report jobs are cancelled when streams are recovered
  - Orphaned streams are handled correctly
  - Race conditions between recovery and report generation
  """

  use Pavoi.DataCase, async: true
  use Oban.Testing, repo: Pavoi.Repo

  import Pavoi.TiktokLiveFixtures

  alias Pavoi.Repo
  alias Pavoi.TiktokLive.StreamReconciler
  alias Pavoi.Workers.StreamReportWorker

  describe "cancel_pending_report_jobs/1" do
    test "cancels pending report jobs for a stream" do
      brand = brand_fixture()
      stream = stream_fixture(brand: brand, status: :ended)

      # Enqueue a report job
      {:ok, job} =
        %{stream_id: stream.id, brand_id: brand.id}
        |> StreamReportWorker.new(schedule_in: 600)
        |> Oban.insert()

      # Job should be scheduled
      assert job.state == "scheduled"

      # Cancel pending jobs
      cancelled_count = StreamReconciler.cancel_pending_report_jobs(stream.id)

      assert cancelled_count == 1

      # Verify job is now cancelled
      updated_job = Repo.get(Oban.Job, job.id)
      assert updated_job.state == "cancelled"
    end

    test "cancels jobs across available, scheduled, and retryable states" do
      brand = brand_fixture()
      stream = stream_fixture(brand: brand, status: :ended)

      # Insert jobs using Oban's API but with different scheduling
      # This avoids unique constraint issues while testing the cancel logic

      # available job
      {:ok, job1} =
        Repo.insert(%Oban.Job{
          worker: "Pavoi.Workers.StreamReportWorker",
          args: %{"stream_id" => stream.id, "brand_id" => brand.id},
          queue: "slack",
          state: "available"
        })

      # scheduled job (different stream to avoid unique)
      stream2 = stream_fixture(brand: brand, status: :ended)

      {:ok, job2} =
        Repo.insert(%Oban.Job{
          worker: "Pavoi.Workers.StreamReportWorker",
          args: %{"stream_id" => stream2.id, "brand_id" => brand.id},
          queue: "slack",
          state: "scheduled",
          scheduled_at: DateTime.add(DateTime.utc_now(), 600, :second)
        })

      # Cancel jobs for stream 1
      cancelled_count1 = StreamReconciler.cancel_pending_report_jobs(stream.id)
      assert cancelled_count1 == 1
      assert Repo.get(Oban.Job, job1.id).state == "cancelled"

      # Cancel jobs for stream 2
      cancelled_count2 = StreamReconciler.cancel_pending_report_jobs(stream2.id)
      assert cancelled_count2 == 1
      assert Repo.get(Oban.Job, job2.id).state == "cancelled"
    end

    test "does not affect jobs for other streams" do
      brand = brand_fixture()
      stream1 = stream_fixture(brand: brand, status: :ended)
      stream2 = stream_fixture(brand: brand, status: :ended)

      # Enqueue jobs for both streams
      {:ok, job1} =
        %{stream_id: stream1.id, brand_id: brand.id}
        |> StreamReportWorker.new(schedule_in: 600)
        |> Oban.insert()

      {:ok, job2} =
        %{stream_id: stream2.id, brand_id: brand.id}
        |> StreamReportWorker.new(schedule_in: 600)
        |> Oban.insert()

      # Cancel only stream1's jobs
      StreamReconciler.cancel_pending_report_jobs(stream1.id)

      # stream1's job should be cancelled
      assert Repo.get(Oban.Job, job1.id).state == "cancelled"

      # stream2's job should still be scheduled
      assert Repo.get(Oban.Job, job2.id).state == "scheduled"
    end

    test "cancels jobs in retryable state" do
      brand = brand_fixture()
      stream = stream_fixture(brand: brand, status: :ended)

      # Insert a job directly in retryable state
      {:ok, job} =
        Repo.insert(%Oban.Job{
          worker: "Pavoi.Workers.StreamReportWorker",
          args: %{"stream_id" => stream.id, "brand_id" => brand.id},
          queue: "slack",
          state: "retryable"
        })

      cancelled_count = StreamReconciler.cancel_pending_report_jobs(stream.id)

      assert cancelled_count == 1
      assert Repo.get(Oban.Job, job.id).state == "cancelled"
    end

    test "does not cancel already completed jobs" do
      brand = brand_fixture()
      stream = stream_fixture(brand: brand, status: :ended)

      # Insert a job directly in completed state
      {:ok, job} =
        Repo.insert(%Oban.Job{
          worker: "Pavoi.Workers.StreamReportWorker",
          args: %{"stream_id" => stream.id, "brand_id" => brand.id},
          queue: "slack",
          state: "completed",
          completed_at: DateTime.utc_now()
        })

      cancelled_count = StreamReconciler.cancel_pending_report_jobs(stream.id)

      assert cancelled_count == 0
      assert Repo.get(Oban.Job, job.id).state == "completed"
    end
  end

  describe "find_orphaned_capturing_streams/0" do
    test "finds streams in capturing state without active jobs" do
      brand = brand_fixture()

      # A capturing stream with no active job
      stream = stream_fixture(brand: brand, status: :capturing)

      orphaned = StreamReconciler.find_orphaned_capturing_streams()

      assert Enum.any?(orphaned, fn s -> s.id == stream.id end)
    end

    test "does not include ended streams" do
      brand = brand_fixture()

      # An ended stream
      stream = stream_fixture(brand: brand, status: :ended)

      orphaned = StreamReconciler.find_orphaned_capturing_streams()

      refute Enum.any?(orphaned, fn s -> s.id == stream.id end)
    end
  end

  describe "find_recently_ended_streams/0" do
    test "finds streams that ended within recovery window" do
      brand = brand_fixture()

      # A stream that ended 30 minutes ago
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      thirty_min_ago = DateTime.add(now, -30, :minute)

      stream =
        stream_fixture(
          brand: brand,
          status: :ended,
          ended_at: thirty_min_ago
        )

      recently_ended = StreamReconciler.find_recently_ended_streams()

      assert Enum.any?(recently_ended, fn s -> s.id == stream.id end)
    end

    test "does not include streams that ended long ago" do
      brand = brand_fixture()

      # A stream that ended 5 hours ago (outside 2-hour window)
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      five_hours_ago = DateTime.add(now, -5, :hour)

      stream =
        stream_fixture(
          brand: brand,
          status: :ended,
          ended_at: five_hours_ago
        )

      recently_ended = StreamReconciler.find_recently_ended_streams()

      refute Enum.any?(recently_ended, fn s -> s.id == stream.id end)
    end
  end

  describe "cancel_stale_stream_jobs/0" do
    test "cancels stale TiktokLiveStreamWorker jobs" do
      # Insert a stale job directly
      {:ok, job} =
        Repo.insert(%Oban.Job{
          worker: "Pavoi.Workers.TiktokLiveStreamWorker",
          args: %{"stream_id" => 999, "unique_id" => "test", "brand_id" => 1},
          queue: "tiktok",
          state: "available"
        })

      cancelled_count = StreamReconciler.cancel_stale_stream_jobs()

      assert cancelled_count >= 1
      assert Repo.get(Oban.Job, job.id).state == "cancelled"
    end

    test "does not affect report worker jobs" do
      brand = brand_fixture()
      stream = stream_fixture(brand: brand, status: :ended)

      # A report worker job
      {:ok, job} =
        %{stream_id: stream.id, brand_id: brand.id}
        |> StreamReportWorker.new()
        |> Oban.insert()

      StreamReconciler.cancel_stale_stream_jobs()

      # Report job should not be affected
      assert Repo.get(Oban.Job, job.id).state == "available"
    end
  end
end
