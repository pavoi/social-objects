defmodule Pavoi.Workers.StreamReportWorkerTest do
  @moduledoc """
  Behavior tests for the StreamReportWorker.

  These tests verify the worker's guards and job processing behavior:
  - Jobs are cancelled for invalid streams
  - Jobs are snoozed when waiting for data
  - Duplicate reports are prevented
  - Race conditions are handled

  Note: These tests verify the worker's decision-making logic, not the actual
  Slack sending (which is disabled in test environment).
  """

  use Pavoi.DataCase, async: true
  use Oban.Testing, repo: Pavoi.Repo

  import Pavoi.TiktokLiveFixtures

  alias Pavoi.Workers.StreamReportWorker

  describe "report guards - stream status" do
    test "cancels job if stream is not ended (capturing)" do
      brand = brand_fixture()
      stream = stream_fixture(brand: brand, status: :capturing)

      job = create_test_job(brand.id, stream.id)

      assert {:cancel, :stream_not_ended} = StreamReportWorker.perform(job)
    end

    test "cancels job if stream is failed" do
      brand = brand_fixture()
      stream = stream_fixture(brand: brand, status: :failed)

      job = create_test_job(brand.id, stream.id)

      assert {:cancel, :stream_not_ended} = StreamReportWorker.perform(job)
    end
  end

  describe "report guards - duplicate prevention" do
    test "cancels job if report was already sent" do
      brand = brand_fixture()
      stream = stream_fixture(brand: brand, status: :ended)
      stream = mark_report_sent(stream)

      job = create_test_job(brand.id, stream.id)

      assert {:cancel, :report_already_sent} = StreamReportWorker.perform(job)
    end
  end

  describe "report guards - nil ended_at handling" do
    test "snoozes job when ended_at is nil" do
      brand = brand_fixture()
      # Create a stream in inconsistent state
      stream = inconsistent_stream_fixture(brand: brand)

      job = create_test_job(brand.id, stream.id)

      # Should snooze to wait for ended_at to be set
      assert {:snooze, seconds} = StreamReportWorker.perform(job)
      assert seconds > 0
    end
  end

  describe "report guards - false start filtering" do
    test "cancels job for very short stream with minimal comments" do
      brand = brand_fixture()

      # Stream lasted only 1 minute with 3 comments
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      one_minute_ago = DateTime.add(now, -60, :second)

      stream =
        stream_fixture(
          brand: brand,
          started_at: one_minute_ago,
          ended_at: now,
          status: :ended,
          total_comments: 3
        )

      job = create_test_job(brand.id, stream.id)

      assert {:cancel, :false_start} = StreamReportWorker.perform(job)
    end

    test "does not cancel for short stream with many comments" do
      brand = brand_fixture()

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      one_minute_ago = DateTime.add(now, -60, :second)

      stream =
        stream_fixture(
          brand: brand,
          started_at: one_minute_ago,
          ended_at: now,
          status: :ended,
          total_comments: 100
        )

      job = create_test_job(brand.id, stream.id)

      # Will try to proceed - either succeeds, fails due to Slack config, or errors
      # but crucially will NOT be cancelled as false_start
      result = StreamReportWorker.perform(job)

      # The key assertion: it should not be cancelled as a false start
      # (it may error due to Slack/OpenAI not configured in test, which is fine)
      refute match?({:cancel, :false_start}, result)
    end

    test "does not cancel for longer stream with few comments" do
      brand = brand_fixture()

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      five_minutes_ago = DateTime.add(now, -5 * 60, :second)

      stream =
        stream_fixture(
          brand: brand,
          started_at: five_minutes_ago,
          ended_at: now,
          status: :ended,
          total_comments: 3
        )

      job = create_test_job(brand.id, stream.id)

      result = StreamReportWorker.perform(job)

      # The key assertion: it should not be cancelled as a false start
      refute match?({:cancel, :false_start}, result)
    end
  end

  describe "stream state changes during processing" do
    test "handles stream being recovered (status changed to capturing)" do
      brand = brand_fixture()
      stream = stream_fixture(brand: brand, status: :ended)

      # Simulate recovery: change status back to capturing before job runs
      stream = recover_stream(stream)

      job = create_test_job(brand.id, stream.id)

      assert {:cancel, :stream_not_ended} = StreamReportWorker.perform(job)
    end

    test "handles stream being deleted" do
      brand = brand_fixture()
      stream = stream_fixture(brand: brand, status: :ended)
      stream_id = stream.id

      # Delete the stream
      Pavoi.Repo.delete(stream)

      job = create_test_job(brand.id, stream_id)

      # Should raise or handle gracefully
      assert_raise Ecto.NoResultsError, fn ->
        StreamReportWorker.perform(job)
      end
    end
  end

  describe "job enqueueing" do
    test "enqueues job with correct args" do
      brand = brand_fixture()
      stream = stream_fixture(brand: brand, status: :ended)

      # Enqueue a job
      {:ok, _job} =
        %{stream_id: stream.id, brand_id: brand.id}
        |> StreamReportWorker.new()
        |> Oban.insert()

      # Verify job was enqueued with correct args
      assert_enqueued(
        worker: StreamReportWorker,
        args: %{stream_id: stream.id, brand_id: brand.id}
      )
    end

    test "enqueues job with delay" do
      brand = brand_fixture()
      stream = stream_fixture(brand: brand, status: :ended)

      # Enqueue with 60 second delay
      {:ok, _job} =
        %{stream_id: stream.id, brand_id: brand.id}
        |> StreamReportWorker.new(schedule_in: 60)
        |> Oban.insert()

      assert_enqueued(
        worker: StreamReportWorker,
        args: %{stream_id: stream.id, brand_id: brand.id}
      )
    end
  end

  # Helper to build a job struct for testing perform/1
  defp create_test_job(brand_id, stream_id) do
    %Oban.Job{
      args: %{"stream_id" => stream_id, "brand_id" => brand_id}
    }
  end
end
