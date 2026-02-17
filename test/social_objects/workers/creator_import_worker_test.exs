defmodule SocialObjects.Workers.CreatorImportWorkerTest do
  @moduledoc """
  Tests for CreatorImportWorker Euka full import functionality.

  These tests verify:
  - CSV parsing with quoted headers and various column orders
  - Import idempotency (re-running doesn't create duplicates)
  - GMV bootstrap flag behavior
  - Quality-aware contact merging
  - Error handling for invalid data
  """

  use SocialObjects.DataCase, async: false
  use Oban.Testing, repo: SocialObjects.Repo

  alias SocialObjects.Creators
  alias SocialObjects.Creators.{CreatorSample, ImportAudit}
  alias SocialObjects.Workers.CreatorImportWorker

  # Define the NimbleCSV parser for test file creation
  NimbleCSV.define(TestCSV, separator: ",", escape: "\"")

  @test_dir "test/fixtures/csv"

  setup do
    # Ensure test fixtures directory exists
    File.mkdir_p!(@test_dir)

    brand = brand_fixture()

    on_exit(fn ->
      # Clean up test files
      File.rm_rf!(@test_dir)
    end)

    %{brand: brand}
  end

  describe "CSV header parsing" do
    test "parses headers with quoted columns containing commas", %{brand: brand} do
      # Create CSV with quoted headers containing commas
      csv_content = """
      handle,email,phone,"PAVOI GMV ALL TIME","PAVOI, VIDEOS POSTED ALL TIME",products_sampled
      testuser1,test@example.com,5551234567,"$100.00",5,""
      """

      file_path = create_test_csv("quoted_headers.csv", csv_content)

      # Should not error on parsing
      result = CreatorImportWorker.import_euka_full_data(file_path, brand.id)

      assert {:ok, stats} = result
      assert stats.created == 1 or stats.updated == 1
    end

    test "handles various column orders", %{brand: brand} do
      # Columns in different order than expected
      csv_content = """
      email,handle,phone,products_sampled,address
      user1@test.com,testuser_order,5559876543,,123 Main St
      """

      file_path = create_test_csv("reordered_columns.csv", csv_content)

      result = CreatorImportWorker.import_euka_full_data(file_path, brand.id)

      assert {:ok, _stats} = result

      # Verify creator was created with correct data
      creator = Creators.get_creator_by_username("testuser_order")
      assert creator != nil
      assert creator.email == "user1@test.com"
    end

    test "ignores unknown columns gracefully", %{brand: brand} do
      csv_content = """
      handle,unknown_column,email,another_unknown
      testuser_unknown,ignored,test@unknown.com,also_ignored
      """

      file_path = create_test_csv("unknown_columns.csv", csv_content)

      result = CreatorImportWorker.import_euka_full_data(file_path, brand.id)

      assert {:ok, _stats} = result

      creator = Creators.get_creator_by_username("testuser_unknown")
      assert creator != nil
      assert creator.email == "test@unknown.com"
    end
  end

  describe "import idempotency" do
    test "re-importing same file is blocked by checksum guard", %{brand: brand} do
      csv_content = """
      handle,email,phone
      idempotent_user,idem@test.com,5551112222
      """

      file_path = create_test_csv("idempotent_test.csv", csv_content)

      # First import succeeds
      result1 = CreatorImportWorker.import_euka_full_data(file_path, brand.id)
      assert {:ok, stats1} = result1
      assert stats1.created == 1

      # Second import is blocked
      result2 = CreatorImportWorker.import_euka_full_data(file_path, brand.id)
      assert {:error, msg} = result2
      assert msg =~ "already" or msg =~ "imported"
    end

    test "creator samples are not duplicated on re-import", %{brand: brand} do
      # Create a product to match
      _product = create_test_product(brand.id, "PAVOI Test Product")

      csv_content = """
      handle,email,products_sampled
      sample_user,sample@test.com,PAVOI Test Product
      """

      # First import
      file_path1 = create_test_csv("samples_test_1.csv", csv_content)
      {:ok, _} = CreatorImportWorker.import_euka_full_data(file_path1, brand.id)

      creator = Creators.get_creator_by_username("sample_user")
      initial_samples = Repo.all(from s in CreatorSample, where: s.creator_id == ^creator.id)

      # Simulate re-import with slightly modified file (different checksum)
      csv_content_v2 = """
      handle,email,products_sampled
      sample_user,sample@test.com,PAVOI Test Product
      """

      file_path2 = create_test_csv("samples_test_2.csv", csv_content_v2 <> "\n")
      {:ok, _} = CreatorImportWorker.import_euka_full_data(file_path2, brand.id)

      # Samples should not be duplicated (unique index on import_source_key)
      final_samples = Repo.all(from s in CreatorSample, where: s.creator_id == ^creator.id)
      assert length(final_samples) == length(initial_samples)
    end
  end

  describe "GMV bootstrap flag" do
    test "seeds GMV and sets gmv_seeded_externally flag", %{brand: brand} do
      csv_content = """
      handle,email,PAVOI GMV ALL TIME
      gmv_user,gmv@test.com,"$500.00"
      """

      file_path = create_test_csv("gmv_test.csv", csv_content)

      {:ok, _} = CreatorImportWorker.import_euka_full_data(file_path, brand.id)

      creator = Creators.get_creator_by_username("gmv_user")
      brand_creator = Creators.get_brand_creator(brand.id, creator.id)

      # $500.00
      assert brand_creator.cumulative_brand_gmv_cents == 50_000
      assert brand_creator.gmv_seeded_externally == true
      assert brand_creator.brand_gmv_tracking_started_at != nil
    end

    test "does not overwrite existing GMV when already seeded", %{brand: brand} do
      # First, create a creator with existing GMV
      csv_content1 = """
      handle,email,PAVOI GMV ALL TIME
      existing_gmv_user,existing@test.com,"$1000.00"
      """

      file_path1 = create_test_csv("existing_gmv_1.csv", csv_content1)
      {:ok, _} = CreatorImportWorker.import_euka_full_data(file_path1, brand.id)

      creator = Creators.get_creator_by_username("existing_gmv_user")
      bc_before = Creators.get_brand_creator(brand.id, creator.id)
      assert bc_before.cumulative_brand_gmv_cents == 100_000

      # Import again with different GMV
      csv_content2 = """
      handle,email,PAVOI GMV ALL TIME
      existing_gmv_user,existing@test.com,"$2000.00"
      """

      file_path2 = create_test_csv("existing_gmv_2.csv", csv_content2 <> "\n")
      {:ok, _} = CreatorImportWorker.import_euka_full_data(file_path2, brand.id)

      bc_after = Creators.get_brand_creator(brand.id, creator.id)
      # Should NOT be overwritten
      assert bc_after.cumulative_brand_gmv_cents == 100_000
    end

    test "first TikTok sync after Euka import skips cumulative delta and resets flag", %{
      brand: brand
    } do
      alias SocialObjects.Creators.BrandGmv

      # Step 1: Import creator with GMV via Euka (sets gmv_seeded_externally=true)
      csv_content = """
      handle,email,PAVOI GMV ALL TIME
      bootstrap_test_user,bootstrap@test.com,"$500.00"
      """

      file_path = create_test_csv("bootstrap_sync_test.csv", csv_content)
      {:ok, _} = CreatorImportWorker.import_euka_full_data(file_path, brand.id)

      creator = Creators.get_creator_by_username("bootstrap_test_user")
      bc_before = Creators.get_brand_creator(brand.id, creator.id)

      # Verify initial state: externally seeded with $500 cumulative
      assert bc_before.cumulative_brand_gmv_cents == 50_000
      assert bc_before.gmv_seeded_externally == true

      # Step 2: Simulate first TikTok sync with some GMV values
      # This is what happens when TikTok analytics sync runs
      now = DateTime.utc_now()
      date = Date.utc_today()
      # $200 in rolling window
      video_gmv = 20_000
      # $100 in rolling window
      live_gmv = 10_000
      # $300 total rolling
      total_gmv = 30_000

      {:ok, :ok} =
        BrandGmv.update_brand_creator_gmv(
          brand.id,
          creator.id,
          video_gmv,
          live_gmv,
          total_gmv,
          date,
          now
        )

      # Step 3: Verify bootstrap guard worked
      bc_after = Creators.get_brand_creator(brand.id, creator.id)

      # Rolling values should be updated
      assert bc_after.brand_gmv_cents == total_gmv
      assert bc_after.brand_video_gmv_cents == video_gmv
      assert bc_after.brand_live_gmv_cents == live_gmv

      # CRITICAL: Cumulative should NOT have increased (delta was skipped)
      # It should still be the original seeded value
      assert bc_after.cumulative_brand_gmv_cents == 50_000

      # Flag should be reset to false
      assert bc_after.gmv_seeded_externally == false

      # Step 4: Verify second sync DOES accumulate deltas
      # Simulate GMV increase
      {:ok, :ok} =
        BrandGmv.update_brand_creator_gmv(
          brand.id,
          creator.id,
          # +$50 video
          25_000,
          # +$50 live
          15_000,
          # +$100 total
          40_000,
          date,
          now
        )

      bc_final = Creators.get_brand_creator(brand.id, creator.id)

      # Now cumulative should have increased by the delta ($100)
      # 50_000 (seeded) + 10_000 (delta: 40_000 - 30_000) = 60_000
      assert bc_final.cumulative_brand_gmv_cents == 60_000
    end
  end

  describe "quality-aware contact merging" do
    test "fills blank fields but does not overwrite existing data", %{brand: brand} do
      # Create creator with existing email, no phone
      {:ok, existing} =
        Creators.create_creator(%{
          tiktok_username: "existing_contact",
          email: "original@test.com"
        })

      csv_content = """
      handle,email,phone
      existing_contact,new@test.com,5551234567
      """

      file_path = create_test_csv("merge_test.csv", csv_content)
      {:ok, _} = CreatorImportWorker.import_euka_full_data(file_path, brand.id)

      updated = Creators.get_creator!(existing.id)

      # Email should NOT be overwritten (existing data preserved)
      assert updated.email == "original@test.com"

      # Phone should be filled (was blank)
      assert updated.phone != nil
    end

    test "does not overwrite manually edited fields", %{brand: brand} do
      # Create creator with manually edited email
      {:ok, existing} =
        Creators.create_creator(%{
          tiktok_username: "manual_edit_test",
          email: "manual@test.com",
          manually_edited_fields: ["email"]
        })

      csv_content = """
      handle,email
      manual_edit_test,import@test.com
      """

      file_path = create_test_csv("manual_edit_test.csv", csv_content)
      {:ok, _} = CreatorImportWorker.import_euka_full_data(file_path, brand.id)

      updated = Creators.get_creator!(existing.id)

      # Email should NOT be overwritten (manually edited)
      assert updated.email == "manual@test.com"
    end

    test "upgrades low-quality data to high-quality", %{brand: brand} do
      # Create creator with low-quality (obfuscated) email
      {:ok, existing} =
        Creators.create_creator(%{
          tiktok_username: "quality_upgrade",
          email: "user***@test.com"
        })

      csv_content = """
      handle,email
      quality_upgrade,realuser@test.com
      """

      file_path = create_test_csv("quality_upgrade.csv", csv_content)
      {:ok, _} = CreatorImportWorker.import_euka_full_data(file_path, brand.id)

      updated = Creators.get_creator!(existing.id)

      # Low-quality email should be replaced with high-quality
      assert updated.email == "realuser@test.com"
    end
  end

  describe "error handling" do
    test "returns error for missing brand_id" do
      result = CreatorImportWorker.import_euka_full_data("/tmp/test.csv", nil)
      assert {:error, msg} = result
      assert msg =~ "brand_id"
    end

    test "raises error for non-existent file", %{brand: brand} do
      # File operations raise File.Error for non-existent files
      assert_raise File.Error, fn ->
        CreatorImportWorker.import_euka_full_data("/nonexistent/path/file.csv", brand.id)
      end
    end

    test "skips rows with missing handle but continues processing", %{brand: brand} do
      csv_content = """
      handle,email
      ,missing_handle@test.com
      valid_user,valid@test.com
      ,also_missing@test.com
      another_valid,another@test.com
      """

      file_path = create_test_csv("missing_handles.csv", csv_content)
      {:ok, stats} = CreatorImportWorker.import_euka_full_data(file_path, brand.id)

      # Should have created 2 valid users, 2 errors
      assert stats.created + stats.updated == 2
      assert stats.errors == 2
    end

    test "sanitizes invalid emails by nullifying them", %{brand: brand} do
      csv_content = """
      handle,email
      invalid_email_user,not-an-email
      """

      file_path = create_test_csv("invalid_email.csv", csv_content)
      {:ok, _} = CreatorImportWorker.import_euka_full_data(file_path, brand.id)

      creator = Creators.get_creator_by_username("invalid_email_user")
      assert creator != nil
      # Invalid email should be nullified, not cause failure
      assert creator.email == nil or creator.email == ""
    end
  end

  describe "product matching" do
    test "matches products by exact name", %{brand: brand} do
      product = create_test_product(brand.id, "PAVOI Exact Match Product")

      csv_content = """
      handle,email,products_sampled
      exact_match_user,exact@test.com,PAVOI Exact Match Product
      """

      file_path = create_test_csv("exact_match.csv", csv_content)
      {:ok, stats} = CreatorImportWorker.import_euka_full_data(file_path, brand.id)

      assert stats.samples == 1

      creator = Creators.get_creator_by_username("exact_match_user")
      samples = Repo.all(from s in CreatorSample, where: s.creator_id == ^creator.id)

      assert length(samples) == 1
      assert hd(samples).product_id == product.id
    end

    test "stores unmatched products in brand_creator", %{brand: brand} do
      csv_content = """
      handle,email,products_sampled
      unmatched_user,unmatched@test.com,PAVOI Nonexistent Product
      """

      file_path = create_test_csv("unmatched.csv", csv_content)
      {:ok, _} = CreatorImportWorker.import_euka_full_data(file_path, brand.id)

      creator = Creators.get_creator_by_username("unmatched_user")
      bc = Creators.get_brand_creator(brand.id, creator.id)

      assert bc.unmatched_products_raw != nil
      assert bc.unmatched_products_raw =~ "PAVOI Nonexistent Product"
    end

    test "deduplicates unmatched products on re-import", %{brand: brand} do
      csv_content = """
      handle,email,products_sampled
      dedupe_user,dedupe@test.com,PAVOI Unknown Item
      """

      # First import
      file_path1 = create_test_csv("dedupe_1.csv", csv_content)
      {:ok, _} = CreatorImportWorker.import_euka_full_data(file_path1, brand.id)

      creator = Creators.get_creator_by_username("dedupe_user")
      bc1 = Creators.get_brand_creator(brand.id, creator.id)
      initial_raw = bc1.unmatched_products_raw

      # Second import with same product
      file_path2 = create_test_csv("dedupe_2.csv", csv_content <> "\n")
      {:ok, _} = CreatorImportWorker.import_euka_full_data(file_path2, brand.id)

      bc2 = Creators.get_brand_creator(brand.id, creator.id)

      # Should not duplicate the unmatched product entry
      assert bc2.unmatched_products_raw == initial_raw
    end
  end

  describe "video and live counts" do
    test "imports video and live counts", %{brand: brand} do
      csv_content = """
      handle,email,PAVOI VIDEOS POSTED ALL TIME,PAVOI LIVES ALL TIME
      counts_user,counts@test.com,25,10
      """

      file_path = create_test_csv("counts.csv", csv_content)
      {:ok, _} = CreatorImportWorker.import_euka_full_data(file_path, brand.id)

      creator = Creators.get_creator_by_username("counts_user")
      bc = Creators.get_brand_creator(brand.id, creator.id)

      assert bc.video_count == 25
      assert bc.live_count == 10
    end
  end

  describe "import audit tracking" do
    test "creates audit record on import", %{brand: brand} do
      csv_content = """
      handle,email
      audit_user,audit@test.com
      """

      file_path = create_test_csv("audit_test.csv", csv_content)
      {:ok, _} = CreatorImportWorker.import_euka_full_data(file_path, brand.id)

      # Check audit was created
      audits =
        Repo.all(
          from a in ImportAudit,
            where: a.brand_id == ^brand.id and a.source == "euka"
        )

      assert length(audits) == 1
      audit = hd(audits)
      assert audit.status == "completed"
      assert audit.creators_created == 1 or audit.creators_updated == 1
    end

    test "creates audit with completed status even for empty data", %{brand: brand} do
      # Create a CSV with headers but no data rows
      csv_content = """
      handle,email
      """

      file_path = create_test_csv("empty_data.csv", csv_content)
      result = CreatorImportWorker.import_euka_full_data(file_path, brand.id)

      # Empty file with no data rows completes successfully with 0 records
      assert {:ok, stats} = result
      assert stats.created == 0
      assert stats.updated == 0

      audits =
        Repo.all(
          from a in ImportAudit,
            where: a.brand_id == ^brand.id and a.source == "euka",
            order_by: [desc: a.inserted_at]
        )

      assert length(audits) >= 1
      audit = hd(audits)
      assert audit.status == "completed"
      assert audit.creators_created == 0
    end
  end

  # Helper functions

  defp create_test_csv(filename, content) do
    path = Path.join(@test_dir, filename)
    File.write!(path, content)
    path
  end

  defp create_test_product(brand_id, name) do
    alias SocialObjects.Catalog

    {:ok, product} =
      Catalog.create_product(brand_id, %{
        name: name,
        original_price_cents: 1000,
        active: true
      })

    product
  end
end
