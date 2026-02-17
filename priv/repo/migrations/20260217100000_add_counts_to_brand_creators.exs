defmodule SocialObjects.Repo.Migrations.AddCountsToBrandCreators do
  use Ecto.Migration

  def change do
    alter table(:brand_creators) do
      # Brand-specific video/live counts (can be seeded from Euka or computed from creator_videos)
      add :video_count, :integer, default: 0
      add :live_count, :integer, default: 0

      # Fallback storage for unmatched product names from external imports
      add :unmatched_products_raw, :text

      # Bootstrap flag for GMV - prevents double-counting on first TikTok sync
      add :gmv_seeded_externally, :boolean, default: false
    end
  end
end
