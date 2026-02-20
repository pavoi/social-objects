defmodule SocialObjects.Workers.VideoSyncWorkerTest do
  use SocialObjects.DataCase, async: false

  import Ecto.Query
  import SocialObjects.TiktokLiveFixtures

  alias SocialObjects.Creators
  alias SocialObjects.Creators.CreatorVideo
  alias SocialObjects.Creators.CreatorVideoMetricSnapshot
  alias SocialObjects.Repo
  alias SocialObjects.Workers.VideoSyncWorker

  setup do
    previous_fetcher = Application.get_env(:social_objects, :video_sync_page_fetcher)

    on_exit(fn ->
      Application.put_env(:social_objects, :video_sync_page_fetcher, previous_fetcher)
    end)

    :ok
  end

  describe "run_sync/2 duplicate handling" do
    test "dedupes conflicting duplicate rows and keeps highest GMV row" do
      brand = brand_fixture()
      video_id = "7535909487669005581"

      set_page_fetcher(fn _brand_id, opts ->
        case Keyword.get(opts, :page_token) do
          nil ->
            {:ok,
             %{
               "data" => %{
                 "videos" => [high_row(video_id)],
                 "next_page_token" => "p2"
               }
             }}

          "p2" ->
            {:ok,
             %{
               "data" => %{
                 "videos" => [low_row(video_id)],
                 "next_page_token" => ""
               }
             }}
        end
      end)

      assert {:ok, stats} =
               VideoSyncWorker.run_sync(brand.id,
                 source_run_id: "test-duplicate-canonical",
                 skip_thumbnails?: true
               )

      video = Creators.get_video_by_tiktok_id(video_id)

      assert video.gmv_cents == 1_668_639
      assert video.impressions == 42_000
      assert video.items_sold == 123

      snapshots =
        from(s in CreatorVideoMetricSnapshot,
          where: s.brand_id == ^brand.id and s.tiktok_video_id == ^video_id,
          select: {s.window_days, s.gmv_cents}
        )
        |> Repo.all()
        |> Enum.sort()

      assert snapshots == [{30, 1_668_639}, {90, 1_668_639}]
      assert stats.duplicate_rows == 2
      assert stats.conflict_video_count == 2
      assert stats.max_conflict_gmv_cents == 1_661_241
    end

    test "existing all-time metrics do not regress when API returns lower row" do
      brand = brand_fixture()
      video_id = "7535909487669005581"

      {:ok, creator} = Creators.create_creator(%{tiktok_username: "dupecreator"})
      _ = Creators.add_creator_to_brand(creator.id, brand.id)

      {:ok, existing_video} =
        %CreatorVideo{brand_id: brand.id, creator_id: creator.id}
        |> CreatorVideo.changeset(%{
          tiktok_video_id: video_id,
          title: "Existing Video",
          gmv_cents: 2_000_000,
          gpm_cents: 30_000,
          impressions: 150_000,
          items_sold: 200,
          posted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.insert()

      set_page_fetcher(fn _brand_id, _opts ->
        {:ok,
         %{
           "data" => %{
             "videos" => [low_row(video_id)],
             "next_page_token" => ""
           }
         }}
      end)

      assert {:ok, _stats} =
               VideoSyncWorker.run_sync(brand.id,
                 source_run_id: "test-monotonic",
                 skip_thumbnails?: true
               )

      updated_video = Repo.get!(CreatorVideo, existing_video.id)

      assert updated_video.gmv_cents == 2_000_000
      assert updated_video.impressions == 150_000
      assert updated_video.items_sold == 200

      snapshot_90 =
        Repo.get_by!(CreatorVideoMetricSnapshot,
          brand_id: brand.id,
          tiktok_video_id: video_id,
          window_days: 90,
          snapshot_date: Date.utc_today()
        )

      assert snapshot_90.gmv_cents == 7_398
    end
  end

  defp set_page_fetcher(fun) do
    Application.put_env(:social_objects, :video_sync_page_fetcher, fun)
  end

  defp high_row(video_id) do
    %{
      "id" => video_id,
      "username" => "dupecreator",
      "title" => "High GMV row",
      "video_post_time" => "2025-12-28 12:34:20",
      "gmv" => %{"amount" => "16686.39"},
      "gpm" => %{"amount" => "238.38"},
      "views" => 42_000,
      "items_sold" => 123,
      "click_through_rate" => "2.4%",
      "duration" => 21,
      "hash_tags" => ["pavoi", "viral"],
      "products" => []
    }
  end

  defp low_row(video_id) do
    %{
      "id" => video_id,
      "username" => "dupecreator",
      "title" => "Low GMV row",
      "video_post_time" => "2025-12-28 12:34:20",
      "gmv" => %{"amount" => "73.98"},
      "gpm" => %{"amount" => "12.10"},
      "views" => 120,
      "items_sold" => 1,
      "click_through_rate" => "0.4%",
      "duration" => 21,
      "hash_tags" => ["pavoi"],
      "products" => []
    }
  end
end
