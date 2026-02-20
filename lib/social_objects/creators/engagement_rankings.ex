defmodule SocialObjects.Creators.EngagementRankings do
  @moduledoc """
  Recomputes brand-scoped creator engagement rankings and system statuses.
  """

  import Ecto.Query

  alias SocialObjects.Creators.BrandCreator
  alias SocialObjects.Creators.CreatorPerformanceSnapshot
  alias SocialObjects.Repo
  alias SocialObjects.Settings

  @vip_cycle_days 90
  @vip_slots 50
  @trending_slots 25

  @spec refresh_brand(pos_integer()) :: {:ok, map()} | {:error, term()}
  def refresh_brand(brand_id) do
    Repo.transaction(fn ->
      today = Date.utc_today()

      brand_creators =
        from(bc in BrandCreator, where: bc.brand_id == ^brand_id)
        |> Repo.all()

      l30_ranked = rank_l30(brand_creators)
      persist_l30_rankings(brand_id, l30_ranked)

      l90_ranked = rank_l90(brand_id, brand_creators, today)
      persist_l90_rankings(brand_id, l90_ranked)

      vip_refreshed? = maybe_refresh_vip_roster(brand_id, l90_ranked, today)
      trending_ids = assign_trending(brand_id, l30_ranked)
      assign_priorities(brand_id)

      %{
        creators_ranked: length(brand_creators),
        vip_refreshed?: vip_refreshed?,
        trending_count: length(trending_ids)
      }
    end)
  end

  defp rank_l30(brand_creators) do
    brand_creators
    |> Enum.sort_by(fn bc ->
      [
        -(bc.brand_gmv_cents || 0),
        -(bc.cumulative_brand_gmv_cents || 0),
        bc.creator_id
      ]
    end)
    |> Enum.with_index(1)
    |> Enum.map(fn {bc, rank} ->
      %{
        creator_id: bc.creator_id,
        l30d_rank: rank,
        l30d_gmv_cents: bc.brand_gmv_cents || 0
      }
    end)
  end

  defp rank_l90(brand_id, brand_creators, today) do
    start_date = Date.add(today, -(@vip_cycle_days - 1))

    stability_by_creator =
      from(s in CreatorPerformanceSnapshot,
        where: s.brand_id == ^brand_id,
        where: s.source == "brand_gmv",
        where: s.snapshot_date >= ^start_date and s.snapshot_date <= ^today,
        group_by: s.creator_id,
        select: {s.creator_id, %{avg_gmv: avg(s.gmv_cents), observations: count(s.id)}}
      )
      |> Repo.all()
      |> Map.new(fn {creator_id, metrics} ->
        avg_gmv = metrics.avg_gmv || Decimal.new(0)
        observations = metrics.observations || 0
        stability_score = stability_score(avg_gmv, observations)
        {creator_id, stability_score}
      end)

    brand_creators
    |> Enum.map(fn bc ->
      %{
        creator_id: bc.creator_id,
        stability_score: Map.get(stability_by_creator, bc.creator_id, 0),
        brand_gmv_cents: bc.brand_gmv_cents || 0,
        cumulative_brand_gmv_cents: bc.cumulative_brand_gmv_cents || 0
      }
    end)
    |> Enum.sort_by(fn row ->
      [
        -row.stability_score,
        -row.brand_gmv_cents,
        -row.cumulative_brand_gmv_cents,
        row.creator_id
      ]
    end)
    |> Enum.with_index(1)
    |> Enum.map(fn {row, rank} ->
      %{
        creator_id: row.creator_id,
        l90d_rank: rank,
        stability_score: row.stability_score
      }
    end)
  end

  defp stability_score(avg_gmv_decimal, observations) do
    average = Decimal.to_float(avg_gmv_decimal)
    coverage = min(observations, @vip_cycle_days) / @vip_cycle_days
    round(average * coverage)
  end

  defp persist_l30_rankings(brand_id, ranked_rows) do
    Enum.each(ranked_rows, fn row ->
      from(bc in BrandCreator,
        where: bc.brand_id == ^brand_id and bc.creator_id == ^row.creator_id
      )
      |> Repo.update_all(
        set: [
          l30d_rank: row.l30d_rank,
          l30d_gmv_cents: row.l30d_gmv_cents,
          updated_at: now_naive()
        ]
      )
    end)
  end

  defp persist_l90_rankings(brand_id, ranked_rows) do
    Enum.each(ranked_rows, fn row ->
      from(bc in BrandCreator,
        where: bc.brand_id == ^brand_id and bc.creator_id == ^row.creator_id
      )
      |> Repo.update_all(
        set: [
          l90d_rank: row.l90d_rank,
          stability_score: row.stability_score,
          updated_at: now_naive()
        ]
      )
    end)
  end

  defp maybe_refresh_vip_roster(brand_id, l90_ranked, today) do
    cycle_started_at = Settings.get_vip_cycle_started_at(brand_id)

    cycle_due? =
      is_nil(cycle_started_at) or Date.diff(today, cycle_started_at) >= @vip_cycle_days

    if cycle_due? do
      locked_ids =
        from(bc in BrandCreator,
          where: bc.brand_id == ^brand_id and bc.vip_locked == true,
          select: bc.creator_id
        )
        |> Repo.all()

      remaining_slots = max(@vip_slots - length(locked_ids), 0)

      ranked_ids =
        l90_ranked
        |> Enum.map(& &1.creator_id)
        |> Enum.reject(&(&1 in locked_ids))
        |> Enum.take(remaining_slots)

      vip_ids = MapSet.new(locked_ids ++ ranked_ids)

      from(bc in BrandCreator, where: bc.brand_id == ^brand_id and bc.vip_locked == false)
      |> Repo.update_all(set: [is_vip: false, updated_at: now_naive()])

      if MapSet.size(vip_ids) > 0 do
        from(bc in BrandCreator,
          where: bc.brand_id == ^brand_id and bc.creator_id in ^MapSet.to_list(vip_ids)
        )
        |> Repo.update_all(set: [is_vip: true, updated_at: now_naive()])
      end

      _ = Settings.update_vip_cycle_started_at(brand_id, today)
      true
    else
      false
    end
  end

  defp assign_trending(brand_id, l30_ranked) do
    trending_ids =
      l30_ranked
      |> Enum.take(@trending_slots)
      |> Enum.map(& &1.creator_id)

    from(bc in BrandCreator, where: bc.brand_id == ^brand_id)
    |> Repo.update_all(set: [is_trending: false, updated_at: now_naive()])

    if trending_ids != [] do
      from(bc in BrandCreator, where: bc.brand_id == ^brand_id and bc.creator_id in ^trending_ids)
      |> Repo.update_all(set: [is_trending: true, updated_at: now_naive()])
    end

    trending_ids
  end

  defp assign_priorities(brand_id) do
    # Single bulk UPDATE using CASE for MECE segment assignment
    sql = """
    UPDATE brand_creators
    SET engagement_priority = CASE
      WHEN is_trending = true AND is_vip = false THEN 'rising_star'
      WHEN is_vip = true AND is_trending = true THEN 'vip_elite'
      WHEN is_vip = true AND is_trending = false AND (l90d_rank IS NULL OR l90d_rank <= 30) THEN 'vip_stable'
      WHEN is_vip = true AND l90d_rank > 30 THEN 'vip_at_risk'
      ELSE NULL
    END,
    updated_at = NOW()
    WHERE brand_id = $1
    """

    Repo.query!(sql, [brand_id])
  end

  defp now_naive do
    NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
  end
end
