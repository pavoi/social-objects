defmodule SocialObjects.Creators.EngagementRankingsTest do
  use SocialObjects.DataCase, async: true

  alias SocialObjects.Creators
  alias SocialObjects.Creators.BrandCreator
  alias SocialObjects.Creators.CreatorPerformanceSnapshot
  alias SocialObjects.Creators.EngagementRankings
  alias SocialObjects.Settings

  test "assigns deterministic L30 ranks using brand GMV tie-breakers" do
    brand = brand_fixture()

    creator_a =
      creator_for_brand(brand.id, brand_gmv_cents: 500_000, cumulative_brand_gmv_cents: 2_000_000)

    creator_b =
      creator_for_brand(brand.id, brand_gmv_cents: 500_000, cumulative_brand_gmv_cents: 2_000_000)

    creator_c =
      creator_for_brand(brand.id, brand_gmv_cents: 400_000, cumulative_brand_gmv_cents: 9_000_000)

    assert {:ok, _stats} = EngagementRankings.refresh_brand(brand.id)

    bc_a = Repo.get_by!(BrandCreator, brand_id: brand.id, creator_id: creator_a.id)
    bc_b = Repo.get_by!(BrandCreator, brand_id: brand.id, creator_id: creator_b.id)
    bc_c = Repo.get_by!(BrandCreator, brand_id: brand.id, creator_id: creator_c.id)

    # Same GMV + cumulative GMV -> creator_id ASC decides
    assert bc_a.l30d_rank < bc_b.l30d_rank
    assert bc_c.l30d_rank == 3

    assert bc_a.l30d_gmv_cents == bc_a.brand_gmv_cents
    assert bc_b.l30d_gmv_cents == bc_b.brand_gmv_cents
    assert bc_c.l30d_gmv_cents == bc_c.brand_gmv_cents
  end

  test "computes L90 stability ranks from brand_gmv snapshots only" do
    brand = brand_fixture()

    creator_high =
      creator_for_brand(brand.id, brand_gmv_cents: 250_000, cumulative_brand_gmv_cents: 1_000_000)

    creator_low =
      creator_for_brand(brand.id, brand_gmv_cents: 240_000, cumulative_brand_gmv_cents: 900_000)

    insert_snapshot(brand.id, creator_high.id, ~D[2026-02-18], "brand_gmv", 900_000)
    insert_snapshot(brand.id, creator_high.id, ~D[2026-02-19], "brand_gmv", 850_000)
    insert_snapshot(brand.id, creator_low.id, ~D[2026-02-18], "brand_gmv", 100_000)
    insert_snapshot(brand.id, creator_low.id, ~D[2026-02-19], "brand_gmv", 120_000)

    # Large non-brand source data should not affect stability ranking
    insert_snapshot(brand.id, creator_low.id, ~D[2026-02-20], "refunnel", 9_999_999)

    assert {:ok, _stats} = EngagementRankings.refresh_brand(brand.id)

    high_bc = Repo.get_by!(BrandCreator, brand_id: brand.id, creator_id: creator_high.id)
    low_bc = Repo.get_by!(BrandCreator, brand_id: brand.id, creator_id: creator_low.id)

    assert high_bc.stability_score > low_bc.stability_score
    assert high_bc.l90d_rank < low_bc.l90d_rank
  end

  test "refreshes VIP roster only on cycle boundary and preserves vip_locked creators" do
    brand = brand_fixture()
    _ = Settings.update_vip_cycle_started_at(brand.id, Date.add(Date.utc_today(), -95))

    locked_low_creator =
      creator_for_brand(
        brand.id,
        brand_gmv_cents: 1,
        cumulative_brand_gmv_cents: 1,
        is_vip: true,
        vip_locked: true
      )

    insert_snapshot(brand.id, locked_low_creator.id, Date.utc_today(), "brand_gmv", 1)

    regular_creators =
      for i <- 1..50 do
        creator =
          creator_for_brand(
            brand.id,
            brand_gmv_cents: 200_000 - i,
            cumulative_brand_gmv_cents: 500_000 - i
          )

        insert_snapshot(brand.id, creator.id, Date.utc_today(), "brand_gmv", 200_000 - i)
        creator
      end

    assert {:ok, _stats} = EngagementRankings.refresh_brand(brand.id)

    locked_bc = Repo.get_by!(BrandCreator, brand_id: brand.id, creator_id: locked_low_creator.id)
    assert locked_bc.is_vip

    excluded_creator = List.last(regular_creators)
    excluded_bc = Repo.get_by!(BrandCreator, brand_id: brand.id, creator_id: excluded_creator.id)
    refute excluded_bc.is_vip

    assert Settings.get_vip_cycle_started_at(brand.id) == Date.utc_today()
  end

  test "does not refresh VIP roster inside active cycle" do
    brand = brand_fixture()
    _ = Settings.update_vip_cycle_started_at(brand.id, Date.utc_today())

    creator_a =
      creator_for_brand(brand.id,
        is_vip: true,
        brand_gmv_cents: 1_000,
        cumulative_brand_gmv_cents: 1_000
      )

    creator_b =
      creator_for_brand(brand.id,
        is_vip: false,
        brand_gmv_cents: 2_000,
        cumulative_brand_gmv_cents: 2_000
      )

    insert_snapshot(brand.id, creator_a.id, Date.utc_today(), "brand_gmv", 100)
    insert_snapshot(brand.id, creator_b.id, Date.utc_today(), "brand_gmv", 100_000)

    assert {:ok, _stats} = EngagementRankings.refresh_brand(brand.id)

    bc_a = Repo.get_by!(BrandCreator, brand_id: brand.id, creator_id: creator_a.id)
    bc_b = Repo.get_by!(BrandCreator, brand_id: brand.id, creator_id: creator_b.id)

    assert bc_a.is_vip
    refute bc_b.is_vip
  end

  test "assigns MECE engagement priorities based on VIP and trending status" do
    brand = brand_fixture()
    _ = Settings.update_vip_cycle_started_at(brand.id, Date.add(Date.utc_today(), -95))

    # Create VIP creators with different trending/L90 status
    # vip_trending_creator: highest L30 GMV (trending) and high L90 score (VIP) -> vip_elite
    vip_trending_creator =
      creator_for_brand(brand.id,
        brand_gmv_cents: 500_000,
        cumulative_brand_gmv_cents: 2_000_000
      )

    insert_snapshot(brand.id, vip_trending_creator.id, Date.utc_today(), "brand_gmv", 500_000)

    # vip_stable_creator: moderate L30 GMV (not trending) but high L90 score (VIP) -> vip_stable
    vip_stable_creator =
      creator_for_brand(brand.id,
        brand_gmv_cents: 50_000,
        cumulative_brand_gmv_cents: 400_000
      )

    insert_snapshot(brand.id, vip_stable_creator.id, Date.utc_today(), "brand_gmv", 400_000)

    # Create 26 other creators to fill trending (top 25) - all with lower L30 GMV than vip_trending_creator
    # but higher than vip_stable_creator's brand_gmv_cents (50,000)
    for i <- 1..26 do
      creator =
        creator_for_brand(brand.id,
          brand_gmv_cents: 100_000 + i,
          cumulative_brand_gmv_cents: 200_000 + i
        )

      insert_snapshot(brand.id, creator.id, Date.utc_today(), "brand_gmv", 200_000 + i)
    end

    assert {:ok, _stats} = EngagementRankings.refresh_brand(brand.id)

    vip_trending_bc =
      Repo.get_by!(BrandCreator, brand_id: brand.id, creator_id: vip_trending_creator.id)

    assert vip_trending_bc.is_vip
    assert vip_trending_bc.is_trending
    assert vip_trending_bc.engagement_priority == :vip_elite

    vip_stable_bc =
      Repo.get_by!(BrandCreator, brand_id: brand.id, creator_id: vip_stable_creator.id)

    assert vip_stable_bc.is_vip
    refute vip_stable_bc.is_trending
    assert vip_stable_bc.engagement_priority == :vip_stable
  end

  test "assigns rising_star to non-VIP creators in L30 top 75" do
    brand = brand_fixture()
    _ = Settings.update_vip_cycle_started_at(brand.id, Date.utc_today())

    # Non-VIP with L30 rank 60 -> rising_star
    rising_creator = creator_for_brand(brand.id, brand_gmv_cents: 50_000, is_vip: false)
    insert_snapshot(brand.id, rising_creator.id, Date.utc_today(), "brand_gmv", 50_000)

    # Non-VIP with L30 rank 80 -> nil (outside cutoff)
    unclassified_creator = creator_for_brand(brand.id, brand_gmv_cents: 10_000, is_vip: false)
    insert_snapshot(brand.id, unclassified_creator.id, Date.utc_today(), "brand_gmv", 10_000)

    # Create enough creators to push our test creators to appropriate ranks
    for i <- 1..80 do
      creator = creator_for_brand(brand.id, brand_gmv_cents: 100_000 - i * 1000)
      insert_snapshot(brand.id, creator.id, Date.utc_today(), "brand_gmv", 100_000 - i * 1000)
    end

    assert {:ok, _stats} = EngagementRankings.refresh_brand(brand.id)

    rising_bc = Repo.get_by!(BrandCreator, brand_id: brand.id, creator_id: rising_creator.id)
    refute rising_bc.is_vip
    assert rising_bc.l30d_rank <= 75
    assert rising_bc.engagement_priority == :rising_star

    unclassified_bc =
      Repo.get_by!(BrandCreator, brand_id: brand.id, creator_id: unclassified_creator.id)

    refute unclassified_bc.is_vip
    assert unclassified_bc.l30d_rank > 75
    assert is_nil(unclassified_bc.engagement_priority)
  end

  test "VIP creators are not classified as rising_star regardless of L30 rank" do
    brand = brand_fixture()
    _ = Settings.update_vip_cycle_started_at(brand.id, Date.add(Date.utc_today(), -95))

    # High-performing creator who will become VIP
    vip_creator = creator_for_brand(brand.id, brand_gmv_cents: 500_000)
    insert_snapshot(brand.id, vip_creator.id, Date.utc_today(), "brand_gmv", 500_000)

    assert {:ok, _stats} = EngagementRankings.refresh_brand(brand.id)

    vip_bc = Repo.get_by!(BrandCreator, brand_id: brand.id, creator_id: vip_creator.id)
    assert vip_bc.is_vip
    assert vip_bc.engagement_priority in [:vip_elite, :vip_stable, :vip_at_risk]
    refute vip_bc.engagement_priority == :rising_star
  end

  defp creator_for_brand(brand_id, brand_creator_attrs, creator_attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    creator_params =
      Map.merge(
        %{
          tiktok_username: "engage-rank-#{unique}"
        },
        Map.new(creator_attrs)
      )

    {:ok, creator} =
      Creators.create_creator(creator_params)

    _ = Creators.add_creator_to_brand(creator.id, brand_id)

    brand_creator = Creators.get_brand_creator(brand_id, creator.id)

    {:ok, _updated} = Creators.update_brand_creator(brand_creator, Map.new(brand_creator_attrs))
    creator
  end

  defp insert_snapshot(brand_id, creator_id, date, source, gmv_cents) do
    attrs = %{
      creator_id: creator_id,
      snapshot_date: date,
      source: source,
      gmv_cents: gmv_cents,
      gmv_delta_cents: gmv_cents
    }

    {:ok, _snapshot} =
      %CreatorPerformanceSnapshot{brand_id: brand_id}
      |> CreatorPerformanceSnapshot.changeset(attrs)
      |> Repo.insert()
  end
end
