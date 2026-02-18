defmodule SocialObjects.Workers.TiktokLiveMonitorWorkerTest do
  use SocialObjects.DataCase, async: false
  use Oban.Testing, repo: SocialObjects.Repo

  import SocialObjects.TiktokLiveFixtures

  alias SocialObjects.Settings.SystemSetting
  alias SocialObjects.TiktokLive.Stream

  alias SocialObjects.Workers.{
    StreamReportWorker,
    TiktokLiveMonitorWorker,
    TiktokLiveStreamWorker
  }

  setup do
    previous_fetcher = Application.get_env(:social_objects, :tiktok_live_room_info_fetcher)

    on_exit(fn ->
      if is_nil(previous_fetcher) do
        Application.delete_env(:social_objects, :tiktok_live_room_info_fetcher)
      else
        Application.put_env(:social_objects, :tiktok_live_room_info_fetcher, previous_fetcher)
      end
    end)

    :ok
  end

  describe "handle_not_live safeguards" do
    test "does not mark stream ended when capture worker is active" do
      brand = brand_fixture()
      unique_id = "monitor_user_active"
      create_system_setting(brand.id, "tiktok_live_accounts", unique_id)

      stream =
        stream_fixture(
          brand: brand,
          unique_id: unique_id,
          status: :capturing
        )

      {:ok, _capture_job} =
        %{stream_id: stream.id, unique_id: unique_id, brand_id: brand.id}
        |> TiktokLiveStreamWorker.new()
        |> Oban.insert()

      Application.put_env(:social_objects, :tiktok_live_room_info_fetcher, fn ^unique_id ->
        {:ok, %{is_live: false}}
      end)

      assert :ok =
               perform_job(TiktokLiveMonitorWorker, %{"brand_id" => brand.id, "source" => "test"})

      updated_stream = Repo.get!(Stream, stream.id)
      assert updated_stream.status == :capturing
      assert is_nil(updated_stream.ended_at)

      refute_enqueued(
        worker: StreamReportWorker,
        args: %{stream_id: stream.id, brand_id: brand.id}
      )
    end

    test "marks stream ended and enqueues report when capture worker is inactive" do
      brand = brand_fixture()
      unique_id = "monitor_user_inactive"
      create_system_setting(brand.id, "tiktok_live_accounts", unique_id)

      stream =
        stream_fixture(
          brand: brand,
          unique_id: unique_id,
          status: :capturing
        )

      Application.put_env(:social_objects, :tiktok_live_room_info_fetcher, fn ^unique_id ->
        {:ok, %{is_live: false}}
      end)

      assert :ok =
               perform_job(TiktokLiveMonitorWorker, %{"brand_id" => brand.id, "source" => "test"})

      updated_stream = Repo.get!(Stream, stream.id)
      assert updated_stream.status == :ended
      assert not is_nil(updated_stream.ended_at)

      assert_enqueued(
        worker: StreamReportWorker,
        args: %{stream_id: stream.id, brand_id: brand.id}
      )
    end
  end

  describe "resume_capture behavior" do
    test "cancels pending report jobs and clears report_sent_at when resuming same room" do
      brand = brand_fixture()
      unique_id = "monitor_user_resume"
      create_system_setting(brand.id, "tiktok_live_accounts", unique_id)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      stream =
        stream_fixture(
          brand: brand,
          unique_id: unique_id,
          room_id: "resume_room_123",
          status: :ended,
          ended_at: DateTime.add(now, -5, :minute),
          report_sent_at: DateTime.add(now, -4, :minute)
        )

      {:ok, report_job} =
        %{stream_id: stream.id, brand_id: brand.id}
        |> StreamReportWorker.new(schedule_in: 600)
        |> Oban.insert()

      Application.put_env(:social_objects, :tiktok_live_room_info_fetcher, fn ^unique_id ->
        {:ok,
         %{
           is_live: true,
           room_id: stream.room_id,
           title: "Resumed stream",
           viewer_count: 25
         }}
      end)

      assert :ok =
               perform_job(TiktokLiveMonitorWorker, %{"brand_id" => brand.id, "source" => "test"})

      updated_stream = Repo.get!(Stream, stream.id)
      assert updated_stream.status == :capturing
      assert is_nil(updated_stream.ended_at)
      assert is_nil(updated_stream.report_sent_at)

      assert Repo.get!(Oban.Job, report_job.id).state == "cancelled"

      assert_enqueued(
        worker: TiktokLiveStreamWorker,
        args: %{stream_id: stream.id, unique_id: unique_id, brand_id: brand.id}
      )
    end
  end

  defp create_system_setting(brand_id, key, value) do
    %SystemSetting{}
    |> SystemSetting.changeset(%{
      brand_id: brand_id,
      key: key,
      value: value,
      value_type: "string"
    })
    |> Repo.insert!()
  end
end
