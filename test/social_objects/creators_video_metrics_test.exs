defmodule SocialObjects.CreatorsVideoMetricsTest do
  use SocialObjects.DataCase, async: true

  import SocialObjects.TiktokLiveFixtures

  alias SocialObjects.Creators
  alias SocialObjects.Creators.CreatorVideo
  alias SocialObjects.Repo

  describe "search_videos_paginated/1 with period metrics" do
    test "switches metric source and sorting based on period" do
      brand = brand_fixture()
      creator = creator_fixture(brand.id)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      video_all_time_leader =
        video_fixture(brand.id, creator.id, %{
          tiktok_video_id: "all-time-leader",
          title: "All Time Leader",
          posted_at: DateTime.add(now, -180, :day),
          gmv_cents: 1_000_000,
          impressions: 12_000,
          items_sold: 40,
          gpm_cents: 20_000,
          ctr: Decimal.new("2.4")
        })

      video_period_leader =
        video_fixture(brand.id, creator.id, %{
          tiktok_video_id: "period-leader",
          title: "Period Leader",
          posted_at: DateTime.add(now, -2, :day),
          gmv_cents: 500_000,
          impressions: 10_000,
          items_sold: 20,
          gpm_cents: 15_000,
          ctr: Decimal.new("1.8")
        })

      _ =
        Creators.upsert_video_metric_snapshots([
          %{
            brand_id: brand.id,
            creator_video_id: video_all_time_leader.id,
            tiktok_video_id: video_all_time_leader.tiktok_video_id,
            snapshot_date: Date.utc_today(),
            window_days: 30,
            gmv_cents: 100_000,
            views: 2_000,
            items_sold: 4,
            gpm_cents: 5_000,
            ctr: Decimal.new("0.7")
          },
          %{
            brand_id: brand.id,
            creator_video_id: video_period_leader.id,
            tiktok_video_id: video_period_leader.tiktok_video_id,
            snapshot_date: Date.utc_today(),
            window_days: 30,
            gmv_cents: 800_000,
            views: 8_000,
            items_sold: 35,
            gpm_cents: 30_000,
            ctr: Decimal.new("4.1")
          },
          %{
            brand_id: brand.id,
            creator_video_id: video_all_time_leader.id,
            tiktok_video_id: video_all_time_leader.tiktok_video_id,
            snapshot_date: Date.utc_today(),
            window_days: 90,
            gmv_cents: 900_000,
            views: 10_000,
            items_sold: 30,
            gpm_cents: 18_000,
            ctr: Decimal.new("2.2")
          },
          %{
            brand_id: brand.id,
            creator_video_id: video_period_leader.id,
            tiktok_video_id: video_period_leader.tiktok_video_id,
            snapshot_date: Date.utc_today(),
            window_days: 90,
            gmv_cents: 300_000,
            views: 4_000,
            items_sold: 12,
            gpm_cents: 12_000,
            ctr: Decimal.new("1.9")
          }
        ])

      all_time =
        Creators.search_videos_paginated(
          brand_id: brand.id,
          period: "all",
          sort_by: "gmv",
          sort_dir: "desc",
          per_page: 50
        )

      assert Enum.map(all_time.videos, & &1.id) == [
               video_all_time_leader.id,
               video_period_leader.id
             ]

      period_30 =
        Creators.search_videos_paginated(
          brand_id: brand.id,
          period: "30",
          sort_by: "gmv",
          sort_dir: "desc",
          per_page: 50
        )

      assert Enum.map(period_30.videos, & &1.id) == [
               video_period_leader.id,
               video_all_time_leader.id
             ]

      assert Enum.any?(period_30.videos, &(&1.id == video_all_time_leader.id))

      period_30_min =
        Creators.search_videos_paginated(
          brand_id: brand.id,
          period: "30",
          sort_by: "gmv",
          sort_dir: "desc",
          min_gmv: 700_000,
          per_page: 50
        )

      assert Enum.map(period_30_min.videos, & &1.id) == [video_period_leader.id]

      all_time_min =
        Creators.search_videos_paginated(
          brand_id: brand.id,
          period: "all",
          sort_by: "gmv",
          sort_dir: "desc",
          min_gmv: 700_000,
          per_page: 50
        )

      assert Enum.map(all_time_min.videos, & &1.id) == [video_all_time_leader.id]
    end

    test "uses latest snapshot date for selected window" do
      brand = brand_fixture()
      creator = creator_fixture(brand.id)

      video =
        video_fixture(brand.id, creator.id, %{
          tiktok_video_id: "latest-snapshot-video",
          title: "Latest Snapshot Video",
          gmv_cents: 400_000,
          impressions: 7_000,
          items_sold: 14
        })

      _ =
        Creators.upsert_video_metric_snapshots([
          %{
            brand_id: brand.id,
            creator_video_id: video.id,
            tiktok_video_id: video.tiktok_video_id,
            snapshot_date: Date.add(Date.utc_today(), -1),
            window_days: 30,
            gmv_cents: 900_000,
            views: 11_000,
            items_sold: 20,
            gpm_cents: 21_000,
            ctr: Decimal.new("4.0")
          },
          %{
            brand_id: brand.id,
            creator_video_id: video.id,
            tiktok_video_id: video.tiktok_video_id,
            snapshot_date: Date.utc_today(),
            window_days: 30,
            gmv_cents: 300_000,
            views: 3_000,
            items_sold: 5,
            gpm_cents: 10_000,
            ctr: Decimal.new("1.0")
          }
        ])

      result =
        Creators.search_videos_paginated(
          brand_id: brand.id,
          period: "30",
          sort_by: "gmv",
          sort_dir: "desc",
          per_page: 10
        )

      [returned] = result.videos
      assert returned.id == video.id
      assert returned.gmv_cents == 300_000
      assert returned.impressions == 3_000
      assert returned.items_sold == 5
    end
  end

  defp creator_fixture(brand_id) do
    {:ok, creator} =
      Creators.create_creator(%{
        tiktok_username: "video_metrics_creator_#{System.unique_integer([:positive])}"
      })

    _ = Creators.add_creator_to_brand(creator.id, brand_id)
    creator
  end

  defp video_fixture(brand_id, creator_id, attrs) do
    {:ok, video} =
      %CreatorVideo{brand_id: brand_id, creator_id: creator_id}
      |> CreatorVideo.changeset(attrs)
      |> Repo.insert()

    video
  end
end
