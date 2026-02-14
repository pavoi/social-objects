defmodule SocialObjects.Repo.Migrations.AddBrandContentGmvFields do
  use Ecto.Migration

  def change do
    # Add brand-specific content GMV tracking fields to brand_creators
    alter table(:brand_creators) do
      # Rolling 30-day GMV from video/live analytics
      add :content_gmv_cents, :bigint, default: 0
      add :content_video_gmv_cents, :bigint, default: 0
      add :content_live_gmv_cents, :bigint, default: 0

      # Cumulative (delta-accumulated)
      add :cumulative_content_gmv_cents, :bigint, default: 0
      add :cumulative_content_video_gmv_cents, :bigint, default: 0
      add :cumulative_content_live_gmv_cents, :bigint, default: 0

      # Tracking metadata
      add :content_gmv_tracking_started_at, :date
      add :content_gmv_last_synced_at, :utc_datetime
    end

    # Index for efficient sorting by content GMV
    create index(:brand_creators, [:content_gmv_cents])
    create index(:brand_creators, [:cumulative_content_gmv_cents])

    # Index for snapshot queries by brand_id + creator_id + date
    create index(:creator_performance_snapshots, [:creator_id, :brand_id, :snapshot_date])
  end
end
