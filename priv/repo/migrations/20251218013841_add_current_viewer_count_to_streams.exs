defmodule Pavoi.Repo.Migrations.AddCurrentViewerCountToStreams do
  use Ecto.Migration

  def change do
    alter table(:tiktok_streams) do
      add :viewer_count_current, :integer, default: 0
    end
  end
end
