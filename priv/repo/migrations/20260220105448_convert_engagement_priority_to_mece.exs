defmodule SocialObjects.Repo.Migrations.ConvertEngagementPriorityToMece do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE brand_creators
    SET engagement_priority = CASE
      WHEN is_trending = true AND is_vip = false THEN 'rising_star'
      WHEN is_vip = true AND is_trending = true THEN 'vip_elite'
      WHEN is_vip = true AND is_trending = false AND (l90d_rank IS NULL OR l90d_rank <= 30) THEN 'vip_stable'
      WHEN is_vip = true AND l90d_rank > 30 THEN 'vip_at_risk'
      ELSE NULL
    END
    """)
  end

  def down do
    execute("""
    UPDATE brand_creators
    SET engagement_priority = CASE
      WHEN engagement_priority = 'rising_star' THEN 'high'
      WHEN engagement_priority = 'vip_elite' THEN 'high'
      WHEN engagement_priority = 'vip_stable' THEN 'medium'
      WHEN engagement_priority = 'vip_at_risk' THEN 'monitor'
      ELSE NULL
    END
    """)
  end
end
