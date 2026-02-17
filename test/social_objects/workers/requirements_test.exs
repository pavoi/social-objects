defmodule SocialObjects.Workers.RequirementsTest do
  use SocialObjects.DataCase, async: true

  alias SocialObjects.Settings.SystemSetting
  alias SocialObjects.TiktokShop.Auth, as: ShopAuth
  alias SocialObjects.Workers.Registry
  alias SocialObjects.Workers.Requirements

  describe "get_brand_capabilities/1" do
    test "returns a map with all capability keys" do
      brand = brand_fixture()
      capabilities = Requirements.get_brand_capabilities(brand.id)

      assert is_map(capabilities)
      assert Map.has_key?(capabilities, :tiktok_auth)
      assert Map.has_key?(capabilities, :shopify)
      assert Map.has_key?(capabilities, :bigquery)
      assert Map.has_key?(capabilities, :live_accounts)
    end

    test "returns false for all capabilities when brand has no configuration" do
      brand = brand_fixture()
      capabilities = Requirements.get_brand_capabilities(brand.id)

      assert capabilities.tiktok_auth == false
      assert capabilities.shopify == false
      assert capabilities.bigquery == false
      assert capabilities.live_accounts == false
    end

    test "returns true for shopify when credentials are configured" do
      brand = brand_fixture()
      create_system_setting(brand.id, "shopify_store_name", "test-store")
      create_system_setting(brand.id, "shopify_client_id", "client-id")
      create_system_setting(brand.id, "shopify_client_secret", "secret")

      capabilities = Requirements.get_brand_capabilities(brand.id)

      assert capabilities.shopify == true
    end

    test "returns true for bigquery when credentials are configured" do
      brand = brand_fixture()
      create_system_setting(brand.id, "bigquery_project_id", "project")
      create_system_setting(brand.id, "bigquery_dataset", "dataset")

      create_system_setting(
        brand.id,
        "bigquery_service_account_email",
        "svc@test.iam.gserviceaccount.com"
      )

      create_system_setting(brand.id, "bigquery_private_key", "key")

      capabilities = Requirements.get_brand_capabilities(brand.id)

      assert capabilities.bigquery == true
    end

    test "returns true for live_accounts when configured" do
      brand = brand_fixture()
      create_system_setting(brand.id, "tiktok_live_accounts", "user1,user2")

      capabilities = Requirements.get_brand_capabilities(brand.id)

      assert capabilities.live_accounts == true
    end

    test "returns true for tiktok_auth when shop auth exists" do
      brand = brand_fixture()
      create_tiktok_shop_auth(brand.id)

      capabilities = Requirements.get_brand_capabilities(brand.id)

      assert capabilities.tiktok_auth == true
    end
  end

  describe "get_brand_capabilities/2" do
    test "returns only requested capabilities" do
      brand = brand_fixture()
      create_tiktok_shop_auth(brand.id)

      capabilities = Requirements.get_brand_capabilities(brand.id, hard: :tiktok_auth)

      assert capabilities == %{tiktok_auth: true}
    end

    test "deduplicates repeated capability requirements" do
      brand = brand_fixture()

      capabilities =
        Requirements.get_brand_capabilities(brand.id, hard: :tiktok_auth, soft: :tiktok_auth)

      assert capabilities == %{tiktok_auth: false}
    end
  end

  describe "can_run?/2" do
    test "returns {:ok, :ready} when all hard requirements are met" do
      capabilities = %{tiktok_auth: true, shopify: true, bigquery: true, live_accounts: true}

      assert {:ok, :ready} = Requirements.can_run?(:tiktok_sync, capabilities)
      assert {:ok, :ready} = Requirements.can_run?(:shopify_sync, capabilities)
      assert {:ok, :ready} = Requirements.can_run?(:bigquery_order_sync, capabilities)
    end

    test "returns {:error, :missing_hard, [...]} when hard requirements are not met" do
      capabilities = %{tiktok_auth: false, shopify: false, bigquery: false, live_accounts: false}

      assert {:error, :missing_hard, [:tiktok_auth]} =
               Requirements.can_run?(:tiktok_sync, capabilities)

      assert {:error, :missing_hard, [:shopify]} =
               Requirements.can_run?(:shopify_sync, capabilities)

      assert {:error, :missing_hard, [:bigquery]} =
               Requirements.can_run?(:bigquery_order_sync, capabilities)
    end

    test "returns {:error, :unknown_worker} for invalid worker keys" do
      capabilities = %{tiktok_auth: true, shopify: true, bigquery: true, live_accounts: true}

      assert {:error, :unknown_worker} = Requirements.can_run?(:nonexistent_worker, capabilities)
    end

    test "allows workers with no requirements to always run" do
      capabilities = %{tiktok_auth: false, shopify: false, bigquery: false, live_accounts: false}

      # Workers with no requirements should always be ready
      assert {:ok, :ready} = Requirements.can_run?(:weekly_stream_recap, capabilities)
      assert {:ok, :ready} = Requirements.can_run?(:creator_import, capabilities)
    end

    test "soft requirements don't block execution" do
      capabilities = %{tiktok_auth: false, shopify: false, bigquery: false, live_accounts: false}

      # gmv_backfill has soft: :tiktok_auth - should still run
      assert {:ok, :ready} = Requirements.can_run?(:gmv_backfill, capabilities)
    end

    test "accepts brand_id and fetches capabilities" do
      brand = brand_fixture()
      create_tiktok_shop_auth(brand.id)

      assert {:ok, :ready} = Requirements.can_run?(:tiktok_sync, brand.id)
    end

    test "accepts worker definition and brand_id" do
      brand = brand_fixture()
      create_tiktok_shop_auth(brand.id)
      worker = Registry.get_worker(:tiktok_sync)

      assert {:ok, :ready} = Requirements.can_run?(worker, brand.id)
    end

    test "live_monitor requires live_accounts, not tiktok_auth" do
      # Live monitor should only need live_accounts configured
      capabilities_with_live = %{
        tiktok_auth: false,
        shopify: false,
        bigquery: false,
        live_accounts: true
      }

      capabilities_with_tiktok = %{
        tiktok_auth: true,
        shopify: false,
        bigquery: false,
        live_accounts: false
      }

      # Should work with only live_accounts
      assert {:ok, :ready} = Requirements.can_run?(:tiktok_live_monitor, capabilities_with_live)

      # Should NOT work with only tiktok_auth
      assert {:error, :missing_hard, [:live_accounts]} =
               Requirements.can_run?(:tiktok_live_monitor, capabilities_with_tiktok)
    end
  end

  describe "missing_requirements/2" do
    test "separates hard and soft requirements correctly" do
      capabilities = %{tiktok_auth: false, shopify: false, bigquery: false, live_accounts: false}

      # tiktok_sync has hard: :tiktok_auth
      result = Requirements.missing_requirements(:tiktok_sync, capabilities)
      assert result.hard == [:tiktok_auth]
      assert result.soft == []

      # gmv_backfill has soft: :tiktok_auth
      result = Requirements.missing_requirements(:gmv_backfill, capabilities)
      assert result.hard == []
      assert result.soft == [:tiktok_auth]
    end

    test "returns empty lists when all requirements are met" do
      capabilities = %{tiktok_auth: true, shopify: true, bigquery: true, live_accounts: true}

      result = Requirements.missing_requirements(:tiktok_sync, capabilities)
      assert result.hard == []
      assert result.soft == []
    end

    test "returns empty lists for unknown workers" do
      capabilities = %{tiktok_auth: true, shopify: true, bigquery: true, live_accounts: true}

      result = Requirements.missing_requirements(:nonexistent_worker, capabilities)
      assert result.hard == []
      assert result.soft == []
    end
  end

  describe "requirement_labels/1" do
    test "converts capability atoms to human-readable labels" do
      labels = Requirements.requirement_labels([:tiktok_auth, :shopify])

      assert "TikTok Shop auth" in labels
      assert "Shopify credentials" in labels
    end

    test "handles all known capabilities" do
      labels =
        Requirements.requirement_labels([:tiktok_auth, :shopify, :bigquery, :live_accounts])

      assert length(labels) == 4
      assert "TikTok Shop auth" in labels
      assert "Shopify credentials" in labels
      assert "BigQuery credentials" in labels
      assert "TikTok live accounts" in labels
    end

    test "handles unknown capabilities gracefully" do
      labels = Requirements.requirement_labels([:unknown_cap])

      assert labels == ["unknown_cap"]
    end
  end

  describe "requirement_label/1" do
    test "returns correct label for each capability" do
      assert Requirements.requirement_label(:tiktok_auth) == "TikTok Shop auth"
      assert Requirements.requirement_label(:shopify) == "Shopify credentials"
      assert Requirements.requirement_label(:bigquery) == "BigQuery credentials"
      assert Requirements.requirement_label(:live_accounts) == "TikTok live accounts"
    end
  end

  describe "default_staleness_hours/1" do
    test "returns correct defaults for each freshness mode" do
      assert Requirements.default_staleness_hours(:scheduled) == 24
      assert Requirements.default_staleness_hours(:weekly) == 192
      assert Requirements.default_staleness_hours(:on_demand) == nil
    end
  end

  describe "effective_staleness_hours/1" do
    test "uses explicit max_staleness_hours when set" do
      worker = %{max_staleness_hours: 48, freshness_mode: :scheduled}
      assert Requirements.effective_staleness_hours(worker) == 48
    end

    test "falls back to freshness_mode default when not set" do
      worker = %{freshness_mode: :scheduled}
      assert Requirements.effective_staleness_hours(worker) == 24

      worker = %{freshness_mode: :weekly}
      assert Requirements.effective_staleness_hours(worker) == 192

      worker = %{freshness_mode: :on_demand}
      assert Requirements.effective_staleness_hours(worker) == nil
    end

    test "defaults to scheduled mode when freshness_mode not set" do
      worker = %{}
      assert Requirements.effective_staleness_hours(worker) == 24
    end
  end

  describe "compute_all_worker_requirements/1" do
    test "returns a map of all workers with requirement info" do
      capabilities = %{tiktok_auth: true, shopify: false, bigquery: true, live_accounts: true}

      result = Requirements.compute_all_worker_requirements(capabilities)

      # Should have an entry for every worker in registry
      all_worker_keys = Registry.all_workers() |> Enum.map(& &1.key)

      for key <- all_worker_keys do
        assert Map.has_key?(result, key), "Missing key: #{key}"
        assert Map.has_key?(result[key], :can_run)
        assert Map.has_key?(result[key], :missing_hard)
        assert Map.has_key?(result[key], :missing_soft)
        assert Map.has_key?(result[key], :missing_hard_labels)
        assert Map.has_key?(result[key], :missing_soft_labels)
      end
    end

    test "correctly identifies runnable workers" do
      capabilities = %{tiktok_auth: true, shopify: false, bigquery: true, live_accounts: true}

      result = Requirements.compute_all_worker_requirements(capabilities)

      # tiktok_sync should be runnable (has tiktok_auth)
      assert result[:tiktok_sync].can_run == true
      assert result[:tiktok_sync].missing_hard == []

      # shopify_sync should NOT be runnable (missing shopify)
      assert result[:shopify_sync].can_run == false
      assert result[:shopify_sync].missing_hard == [:shopify]
      assert "Shopify credentials" in result[:shopify_sync].missing_hard_labels
    end
  end

  describe "registry consistency" do
    test "all workers with requirements have valid capability keys" do
      valid_capabilities = [:tiktok_auth, :shopify, :bigquery, :live_accounts]

      for worker <- Registry.all_workers() do
        requirements = Map.get(worker, :requirements, [])

        for {_type, cap} <- requirements do
          assert cap in valid_capabilities,
                 "Worker #{worker.key} has invalid capability: #{cap}"
        end
      end
    end

    test "all workers have valid freshness_mode" do
      valid_modes = [:scheduled, :weekly, :on_demand]

      for worker <- Registry.all_workers() do
        mode = Map.get(worker, :freshness_mode)

        assert mode in valid_modes,
               "Worker #{worker.key} has invalid freshness_mode: #{inspect(mode)}"
      end
    end

    test "scheduled workers should have requirements defined" do
      # Most scheduled workers should have some requirements
      # This is a sanity check to ensure we're not missing requirements

      scheduled_workers_with_requirements = [
        :shopify_sync,
        :tiktok_sync,
        :product_performance_sync,
        :bigquery_order_sync,
        :creator_enrichment,
        :video_sync,
        :creator_purchase_sync,
        :tiktok_live_monitor,
        :stream_analytics_sync,
        :tiktok_token_refresh
      ]

      for key <- scheduled_workers_with_requirements do
        worker = Registry.get_worker(key)
        requirements = Map.get(worker, :requirements, [])

        assert requirements != [],
               "Scheduled worker #{key} should have requirements defined"
      end
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
