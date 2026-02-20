defmodule SocialObjects.Repo.Migrations.FixRisingStarDefinition do
  use Ecto.Migration

  def up do
    execute """
    UPDATE brand_creators
    SET engagement_priority = CASE
      WHEN is_vip = true AND is_trending = true THEN 'vip_elite'
      WHEN is_vip = true AND is_trending = false AND (l90d_rank IS NULL OR l90d_rank <= 30) THEN 'vip_stable'
      WHEN is_vip = true AND l90d_rank > 30 THEN 'vip_at_risk'
      WHEN is_vip = false AND l30d_rank IS NOT NULL AND l30d_rank <= 75 THEN 'rising_star'
      ELSE NULL
    END,
    updated_at = NOW()
    """
  end

  def down do
    execute """
    UPDATE brand_creators
    SET engagement_priority = CASE
      WHEN is_trending = true AND is_vip = false THEN 'rising_star'
      WHEN is_vip = true AND is_trending = true THEN 'vip_elite'
      WHEN is_vip = true AND is_trending = false AND (l90d_rank IS NULL OR l90d_rank <= 30) THEN 'vip_stable'
      WHEN is_vip = true AND l90d_rank > 30 THEN 'vip_at_risk'
      ELSE NULL
    END,
    updated_at = NOW()
    """
  end
end
