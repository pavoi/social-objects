defmodule Pavoi.Repo.Migrations.AddThumbnailUrlToCreatorVideos do
  use Ecto.Migration

  def change do
    alter table(:creator_videos) do
      add :thumbnail_url, :string
    end
  end
end
