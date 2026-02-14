defmodule SocialObjects.Repo.Migrations.RenameContentGmvToBrandGmv do
  use Ecto.Migration

  def change do
    # Rename content_gmv fields to brand_gmv in brand_creators table
    rename table(:brand_creators), :content_gmv_cents, to: :brand_gmv_cents
    rename table(:brand_creators), :content_video_gmv_cents, to: :brand_video_gmv_cents
    rename table(:brand_creators), :content_live_gmv_cents, to: :brand_live_gmv_cents
    rename table(:brand_creators), :cumulative_content_gmv_cents, to: :cumulative_brand_gmv_cents

    rename table(:brand_creators), :cumulative_content_video_gmv_cents,
      to: :cumulative_brand_video_gmv_cents

    rename table(:brand_creators), :cumulative_content_live_gmv_cents,
      to: :cumulative_brand_live_gmv_cents

    rename table(:brand_creators), :content_gmv_tracking_started_at,
      to: :brand_gmv_tracking_started_at

    rename table(:brand_creators), :content_gmv_last_synced_at, to: :brand_gmv_last_synced_at

    # Update indexes
    drop index(:brand_creators, [:content_gmv_cents])
    drop index(:brand_creators, [:cumulative_content_gmv_cents])
    create index(:brand_creators, [:brand_gmv_cents])
    create index(:brand_creators, [:cumulative_brand_gmv_cents])
  end
end
