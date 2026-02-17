defmodule SocialObjects.Workers.RequirementsConsistencyTest do
  @moduledoc """
  Matrix consistency test that verifies registry -> scheduler -> UI alignment.

  This test ensures that for every worker in the registry:
  1. The requirements are properly defined
  2. The Requirements module correctly evaluates them
  3. The BrandCronWorker would make the same decision
  4. The UI would show the correct disabled state

  This is the key acceptance test for the unified requirements system.
  """
  use SocialObjects.DataCase, async: true
  use Oban.Testing, repo: SocialObjects.Repo

  alias SocialObjects.Settings.SystemSetting
  alias SocialObjects.TiktokShop.Auth, as: ShopAuth
  alias SocialObjects.Workers.BrandCronWorker
  alias SocialObjects.Workers.Registry
  alias SocialObjects.Workers.Requirements

  @all_capabilities %{
    tiktok_auth: true,
    shopify: true,
    bigquery: true,
    live_accounts: true
  }

  @no_capabilities %{
    tiktok_auth: false,
    shopify: false,
    bigquery: false,
    live_accounts: false
  }

  describe "registry -> requirements alignment" do
    test "all workers with hard requirements return :missing_hard when capability is false" do
      for worker <- Registry.all_workers() do
        requirements = Map.get(worker, :requirements, [])
        hard_requirements = for({:hard, cap} <- requirements, do: cap)

        if hard_requirements != [] do
          # If worker has hard requirements, it should fail when those are missing
          result = Requirements.can_run?(worker.key, @no_capabilities)

          assert {:error, :missing_hard, missing} = result,
                 "Worker #{worker.key} should return :missing_hard when capabilities are missing"

          # The missing list should include all hard requirements
          for cap <- hard_requirements do
            assert cap in missing,
                   "Worker #{worker.key}: missing list should include #{cap}"
          end
        end
      end
    end

    test "all workers can run when all capabilities are present" do
      for worker <- Registry.all_workers() do
        result = Requirements.can_run?(worker.key, @all_capabilities)

        assert {:ok, :ready} = result,
               "Worker #{worker.key} should be ready when all capabilities present"
      end
    end

    test "workers with no requirements can always run" do
      workers_without_requirements =
        Registry.all_workers()
        |> Enum.filter(fn w -> Map.get(w, :requirements, []) == [] end)

      for worker <- workers_without_requirements do
        result = Requirements.can_run?(worker.key, @no_capabilities)

        assert {:ok, :ready} = result,
               "Worker #{worker.key} has no requirements but cannot run with empty capabilities"
      end
    end

    test "soft requirements don't block execution" do
      workers_with_soft_only =
        Registry.all_workers()
        |> Enum.filter(fn w ->
          requirements = Map.get(w, :requirements, [])
          hard_caps = for({:hard, cap} <- requirements, do: cap)
          soft_caps = for({:soft, cap} <- requirements, do: cap)
          hard_caps == [] and soft_caps != []
        end)

      for worker <- workers_with_soft_only do
        result = Requirements.can_run?(worker.key, @no_capabilities)

        assert {:ok, :ready} = result,
               "Worker #{worker.key} has only soft requirements but blocked execution"
      end
    end
  end

  describe "scheduler -> UI consistency" do
    test "for each capability state, scheduler and UI agree on can_run" do
      # Generate all permutations of capability states
      capability_states = generate_capability_permutations()

      for caps <- capability_states do
        worker_reqs = Requirements.compute_all_worker_requirements(caps)

        for worker <- Registry.all_workers() do
          # What the scheduler would do
          scheduler_can_run =
            case Requirements.can_run?(worker.key, caps) do
              {:ok, :ready} -> true
              {:error, :missing_hard, _} -> false
              {:error, :unknown_worker} -> false
            end

          # What the UI would show
          ui_can_run = Map.get(worker_reqs, worker.key, %{can_run: true}).can_run

          assert scheduler_can_run == ui_can_run,
                 """
                 Scheduler/UI mismatch for #{worker.key} with capabilities #{inspect(caps)}:
                 Scheduler says: #{scheduler_can_run}
                 UI shows: #{ui_can_run}
                 """
        end
      end
    end
  end

  describe "specific bug fixes" do
    test "Live Monitor requires live_accounts, not tiktok_auth" do
      worker = Registry.get_worker(:tiktok_live_monitor)
      requirements = Map.get(worker, :requirements, [])

      # Should NOT have tiktok_auth requirement
      assert {:hard, :tiktok_auth} not in requirements,
             "Live Monitor should NOT require tiktok_auth"

      # Should have live_accounts requirement
      assert {:hard, :live_accounts} in requirements,
             "Live Monitor SHOULD require live_accounts"

      # Verify behavior: works with only live_accounts
      caps_live_only = %{tiktok_auth: false, shopify: false, bigquery: false, live_accounts: true}
      assert {:ok, :ready} = Requirements.can_run?(:tiktok_live_monitor, caps_live_only)

      # Verify behavior: fails with only tiktok_auth
      caps_tiktok_only = %{
        tiktok_auth: true,
        shopify: false,
        bigquery: false,
        live_accounts: false
      }

      assert {:error, :missing_hard, [:live_accounts]} =
               Requirements.can_run?(:tiktok_live_monitor, caps_tiktok_only)
    end

    test "Creator Enrichment requires tiktok_auth" do
      worker = Registry.get_worker(:creator_enrichment)
      requirements = Map.get(worker, :requirements, [])

      assert {:hard, :tiktok_auth} in requirements,
             "Creator Enrichment should require tiktok_auth"

      caps_no_tiktok = %{tiktok_auth: false, shopify: true, bigquery: true, live_accounts: true}

      assert {:error, :missing_hard, [:tiktok_auth]} =
               Requirements.can_run?(:creator_enrichment, caps_no_tiktok)
    end

    test "Video Sync requires tiktok_auth" do
      worker = Registry.get_worker(:video_sync)
      requirements = Map.get(worker, :requirements, [])

      assert {:hard, :tiktok_auth} in requirements,
             "Video Sync should require tiktok_auth"

      caps_no_tiktok = %{tiktok_auth: false, shopify: true, bigquery: true, live_accounts: true}

      assert {:error, :missing_hard, [:tiktok_auth]} =
               Requirements.can_run?(:video_sync, caps_no_tiktok)
    end

    test "Creator Purchase Sync requires tiktok_auth" do
      worker = Registry.get_worker(:creator_purchase_sync)
      requirements = Map.get(worker, :requirements, [])

      assert {:hard, :tiktok_auth} in requirements,
             "Creator Purchase Sync should require tiktok_auth"

      caps_no_tiktok = %{tiktok_auth: false, shopify: true, bigquery: true, live_accounts: true}

      assert {:error, :missing_hard, [:tiktok_auth]} =
               Requirements.can_run?(:creator_purchase_sync, caps_no_tiktok)
    end

    test "GMV Backfill has soft tiktok_auth requirement" do
      worker = Registry.get_worker(:gmv_backfill)
      requirements = Map.get(worker, :requirements, [])

      # Should have SOFT, not hard requirement
      assert {:soft, :tiktok_auth} in requirements,
             "GMV Backfill should have soft tiktok_auth requirement"

      refute {:hard, :tiktok_auth} in requirements,
             "GMV Backfill should NOT have hard tiktok_auth requirement"

      # Should still run without tiktok_auth
      caps_no_tiktok = %{tiktok_auth: false, shopify: true, bigquery: true, live_accounts: true}
      assert {:ok, :ready} = Requirements.can_run?(:gmv_backfill, caps_no_tiktok)
    end

    test "On-demand workers have :on_demand freshness_mode" do
      on_demand_workers = [
        :creator_import,
        :euka_import,
        :creator_outreach,
        :tiktok_live_stream,
        :stream_report,
        :talking_points,
        :gmv_backfill
      ]

      for key <- on_demand_workers do
        worker = Registry.get_worker(key)

        assert worker.freshness_mode == :on_demand,
               "Worker #{key} should have freshness_mode :on_demand"
      end
    end

    test "Weekly stream recap has :weekly freshness_mode" do
      worker = Registry.get_worker(:weekly_stream_recap)

      assert worker.freshness_mode == :weekly,
             "Weekly Stream Recap should have freshness_mode :weekly"
    end
  end

  describe "scheduled tasks in crontab" do
    @cron_tasks [
      "shopify_sync",
      "tiktok_sync",
      "bigquery_sync",
      "tiktok_token_refresh",
      "tiktok_live_monitor",
      "creator_enrichment",
      "stream_analytics_sync",
      "weekly_stream_recap",
      "video_sync",
      "product_performance_sync",
      "brand_gmv_sync",
      "creator_purchase_sync"
    ]

    test "all cron tasks map to valid workers" do
      # This validates the task_to_worker_key mapping in BrandCronWorker
      for task <- @cron_tasks do
        # The worker key mapping should exist
        # We can't easily check the private mapping, but we can check
        # that performing the job doesn't return :unknown_task
        brand = brand_fixture()

        # Configure all capabilities so the job can run
        create_tiktok_shop_auth(brand.id)
        create_system_setting(brand.id, "shopify_store_name", "store")
        create_system_setting(brand.id, "shopify_client_id", "id")
        create_system_setting(brand.id, "shopify_client_secret", "secret")
        create_system_setting(brand.id, "bigquery_project_id", "proj")
        create_system_setting(brand.id, "bigquery_dataset", "ds")
        create_system_setting(brand.id, "bigquery_service_account_email", "svc@test.iam")
        create_system_setting(brand.id, "bigquery_private_key", "key")
        create_system_setting(brand.id, "tiktok_live_accounts", "user1")

        result = perform_job(BrandCronWorker, %{"task" => task})

        assert result == :ok,
               "Cron task '#{task}' should be recognized and return :ok, got: #{inspect(result)}"
      end
    end
  end

  # Helper functions

  defp generate_capability_permutations do
    for tiktok <- [true, false],
        shopify <- [true, false],
        bigquery <- [true, false],
        live_accounts <- [true, false] do
      %{
        tiktok_auth: tiktok,
        shopify: shopify,
        bigquery: bigquery,
        live_accounts: live_accounts
      }
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
