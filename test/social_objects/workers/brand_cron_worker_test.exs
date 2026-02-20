defmodule SocialObjects.Workers.BrandCronWorkerTest do
  use SocialObjects.DataCase, async: true
  use Oban.Testing, repo: SocialObjects.Repo

  alias SocialObjects.Settings.SystemSetting
  alias SocialObjects.TiktokShop.Auth, as: ShopAuth
  alias SocialObjects.Workers.BrandCronWorker

  describe "perform/1 with tiktok_sync task" do
    test "enqueues jobs for brands with TikTok auth" do
      brand_with_auth = brand_fixture()
      create_tiktok_shop_auth(brand_with_auth.id)

      brand_without_auth = brand_fixture()

      assert :ok = perform_job(BrandCronWorker, %{"task" => "tiktok_sync"})

      # Should have job for brand with auth
      assert_enqueued(
        worker: SocialObjects.Workers.TiktokSyncWorker,
        args: %{"brand_id" => brand_with_auth.id}
      )

      # Should NOT have job for brand without auth
      refute_enqueued(
        worker: SocialObjects.Workers.TiktokSyncWorker,
        args: %{"brand_id" => brand_without_auth.id}
      )
    end
  end

  describe "perform/1 with shopify_sync task" do
    test "enqueues jobs for brands with Shopify credentials" do
      brand_with_shopify = brand_fixture()
      create_system_setting(brand_with_shopify.id, "shopify_store_name", "test")
      create_system_setting(brand_with_shopify.id, "shopify_client_id", "id")
      create_system_setting(brand_with_shopify.id, "shopify_client_secret", "secret")

      brand_without_shopify = brand_fixture()

      assert :ok = perform_job(BrandCronWorker, %{"task" => "shopify_sync"})

      assert_enqueued(
        worker: SocialObjects.Workers.ShopifySyncWorker,
        args: %{"brand_id" => brand_with_shopify.id}
      )

      refute_enqueued(
        worker: SocialObjects.Workers.ShopifySyncWorker,
        args: %{"brand_id" => brand_without_shopify.id}
      )
    end
  end

  describe "perform/1 with bigquery_sync task" do
    test "enqueues jobs for brands with BigQuery credentials" do
      brand_with_bq = brand_fixture()
      create_system_setting(brand_with_bq.id, "bigquery_project_id", "proj")
      create_system_setting(brand_with_bq.id, "bigquery_dataset", "ds")
      create_system_setting(brand_with_bq.id, "bigquery_service_account_email", "svc@test.iam")
      create_system_setting(brand_with_bq.id, "bigquery_private_key", "key")

      brand_without_bq = brand_fixture()

      assert :ok = perform_job(BrandCronWorker, %{"task" => "bigquery_sync"})

      assert_enqueued(
        worker: SocialObjects.Workers.BigQueryOrderSyncWorker,
        args: %{"brand_id" => brand_with_bq.id, "source" => "cron"}
      )

      refute_enqueued(
        worker: SocialObjects.Workers.BigQueryOrderSyncWorker,
        args: %{"brand_id" => brand_without_bq.id, "source" => "cron"}
      )
    end
  end

  describe "perform/1 with tiktok_live_monitor task" do
    test "enqueues jobs for brands with live accounts, not TikTok auth" do
      # Brand with only live accounts (no TikTok Shop auth)
      brand_with_live = brand_fixture()
      create_system_setting(brand_with_live.id, "tiktok_live_accounts", "user1,user2")

      # Brand with only TikTok auth (no live accounts)
      brand_with_auth = brand_fixture()
      create_tiktok_shop_auth(brand_with_auth.id)

      # Brand with neither
      brand_without = brand_fixture()

      assert :ok = perform_job(BrandCronWorker, %{"task" => "tiktok_live_monitor"})

      # Should have job for brand with live accounts
      assert_enqueued(
        worker: SocialObjects.Workers.TiktokLiveMonitorWorker,
        args: %{"brand_id" => brand_with_live.id, "source" => "cron"}
      )

      # Should NOT have job for brand with only TikTok auth
      refute_enqueued(
        worker: SocialObjects.Workers.TiktokLiveMonitorWorker,
        args: %{"brand_id" => brand_with_auth.id, "source" => "cron"}
      )

      # Should NOT have job for brand without any config
      refute_enqueued(
        worker: SocialObjects.Workers.TiktokLiveMonitorWorker,
        args: %{"brand_id" => brand_without.id, "source" => "cron"}
      )
    end
  end

  describe "perform/1 with creator_enrichment task" do
    test "enqueues jobs only for brands with TikTok auth" do
      brand_with_auth = brand_fixture()
      create_tiktok_shop_auth(brand_with_auth.id)

      brand_without_auth = brand_fixture()

      assert :ok = perform_job(BrandCronWorker, %{"task" => "creator_enrichment"})

      # Should have job for brand with auth
      assert_enqueued(
        worker: SocialObjects.Workers.CreatorEnrichmentWorker,
        args: %{"brand_id" => brand_with_auth.id, "source" => "cron"}
      )

      # Should NOT have job for brand without auth
      refute_enqueued(
        worker: SocialObjects.Workers.CreatorEnrichmentWorker,
        args: %{"brand_id" => brand_without_auth.id, "source" => "cron"}
      )
    end
  end

  describe "perform/1 with video_sync task" do
    test "enqueues jobs only for brands with TikTok auth" do
      brand_with_auth = brand_fixture()
      create_tiktok_shop_auth(brand_with_auth.id)

      brand_without_auth = brand_fixture()

      assert :ok = perform_job(BrandCronWorker, %{"task" => "video_sync"})

      # Should have job for brand with auth
      assert_enqueued(
        worker: SocialObjects.Workers.VideoSyncWorker,
        args: %{"brand_id" => brand_with_auth.id}
      )

      # Should NOT have job for brand without auth
      refute_enqueued(
        worker: SocialObjects.Workers.VideoSyncWorker,
        args: %{"brand_id" => brand_without_auth.id}
      )
    end
  end

  describe "perform/1 with creator_purchase_sync task" do
    test "enqueues jobs only for brands with TikTok auth" do
      brand_with_auth = brand_fixture()
      create_tiktok_shop_auth(brand_with_auth.id)

      brand_without_auth = brand_fixture()

      assert :ok = perform_job(BrandCronWorker, %{"task" => "creator_purchase_sync"})

      assert_enqueued(
        worker: SocialObjects.Workers.CreatorPurchaseSyncWorker,
        args: %{"brand_id" => brand_with_auth.id}
      )

      refute_enqueued(
        worker: SocialObjects.Workers.CreatorPurchaseSyncWorker,
        args: %{"brand_id" => brand_without_auth.id}
      )
    end
  end

  describe "perform/1 with creator_engagement_ranking task" do
    test "enqueues jobs only for brands with TikTok auth" do
      brand_with_auth = brand_fixture()
      create_tiktok_shop_auth(brand_with_auth.id)

      brand_without_auth = brand_fixture()

      assert :ok = perform_job(BrandCronWorker, %{"task" => "creator_engagement_ranking"})

      assert_enqueued(
        worker: SocialObjects.Workers.CreatorEngagementRankingWorker,
        args: %{"brand_id" => brand_with_auth.id}
      )

      refute_enqueued(
        worker: SocialObjects.Workers.CreatorEngagementRankingWorker,
        args: %{"brand_id" => brand_without_auth.id}
      )
    end
  end

  describe "perform/1 with weekly_stream_recap task" do
    test "enqueues jobs for all brands regardless of configuration" do
      brand1 = brand_fixture()
      brand2 = brand_fixture()

      assert :ok = perform_job(BrandCronWorker, %{"task" => "weekly_stream_recap"})

      # Should have jobs for both brands (no requirements)
      assert_enqueued(
        worker: SocialObjects.Workers.WeeklyStreamRecapWorker,
        args: %{"brand_id" => brand1.id}
      )

      assert_enqueued(
        worker: SocialObjects.Workers.WeeklyStreamRecapWorker,
        args: %{"brand_id" => brand2.id}
      )
    end
  end

  describe "perform/1 with unknown task" do
    test "returns {:discard, :unknown_task} for unknown tasks" do
      _brand = brand_fixture()

      assert {:discard, :unknown_task} =
               perform_job(BrandCronWorker, %{"task" => "nonexistent_task"})
    end
  end

  describe "perform/1 with multiple brands" do
    test "evaluates each brand independently" do
      # Brand 1: TikTok auth only
      brand1 = brand_fixture()
      create_tiktok_shop_auth(brand1.id)

      # Brand 2: Shopify only
      brand2 = brand_fixture()
      create_system_setting(brand2.id, "shopify_store_name", "store")
      create_system_setting(brand2.id, "shopify_client_id", "id")
      create_system_setting(brand2.id, "shopify_client_secret", "secret")

      # Brand 3: Both
      brand3 = brand_fixture()
      create_tiktok_shop_auth(brand3.id)
      create_system_setting(brand3.id, "shopify_store_name", "store3")
      create_system_setting(brand3.id, "shopify_client_id", "id3")
      create_system_setting(brand3.id, "shopify_client_secret", "secret3")

      # Run TikTok sync
      assert :ok = perform_job(BrandCronWorker, %{"task" => "tiktok_sync"})

      # Brand 1 and 3 should have TikTok jobs
      assert_enqueued(
        worker: SocialObjects.Workers.TiktokSyncWorker,
        args: %{"brand_id" => brand1.id}
      )

      refute_enqueued(
        worker: SocialObjects.Workers.TiktokSyncWorker,
        args: %{"brand_id" => brand2.id}
      )

      assert_enqueued(
        worker: SocialObjects.Workers.TiktokSyncWorker,
        args: %{"brand_id" => brand3.id}
      )

      # Run Shopify sync
      assert :ok = perform_job(BrandCronWorker, %{"task" => "shopify_sync"})

      # Brand 2 and 3 should have Shopify jobs
      refute_enqueued(
        worker: SocialObjects.Workers.ShopifySyncWorker,
        args: %{"brand_id" => brand1.id}
      )

      assert_enqueued(
        worker: SocialObjects.Workers.ShopifySyncWorker,
        args: %{"brand_id" => brand2.id}
      )

      assert_enqueued(
        worker: SocialObjects.Workers.ShopifySyncWorker,
        args: %{"brand_id" => brand3.id}
      )
    end
  end

  # Helper functions

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

  defp create_tiktok_shop_auth(brand_id) do
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, 86_400, :second)

    # Set brand_id directly on struct since changeset doesn't cast it
    %ShopAuth{brand_id: brand_id}
    |> ShopAuth.changeset(%{
      shop_id: "test_shop_#{brand_id}",
      shop_name: "Test Shop",
      shop_code: "TST",
      region: "US",
      access_token: "test_access_token",
      refresh_token: "test_refresh_token",
      access_token_expires_at: expires_at,
      refresh_token_expires_at: DateTime.add(expires_at, 86_400 * 30, :second)
    })
    |> Repo.insert!()
  end
end
