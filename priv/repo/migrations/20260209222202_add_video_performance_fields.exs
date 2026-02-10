defmodule Pavoi.Repo.Migrations.AddVideoPerformanceFields do
  use Ecto.Migration

  def change do
    alter table(:creator_videos) do
      # GPM - GMV per mille (GMV per 1000 views), efficiency metric
      add :gpm_cents, :integer

      # Video duration in seconds
      add :duration, :integer

      # Hashtags used in the video
      add :hash_tags, {:array, :string}, default: []
    end
  end
end
