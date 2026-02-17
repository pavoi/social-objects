defmodule SocialObjects.Repo.Migrations.BackfillProductSampleCounts do
  use Ecto.Migration

  def up do
    execute """
    WITH sample_counts AS (
      SELECT product_id, COUNT(*) as cnt
      FROM creator_samples
      WHERE product_id IS NOT NULL
      GROUP BY product_id
    )
    UPDATE products p
    SET sample_count = COALESCE(sc.cnt, 0),
        sample_count_synced_at = NOW()
    FROM sample_counts sc
    WHERE p.id = sc.product_id
    """
  end

  def down do
    execute "UPDATE products SET sample_count = 0, sample_count_synced_at = NULL"
  end
end
