defmodule SocialObjects.Repo.Migrations.AddThumbnailStorageKeyToCreatorVideos do
  use Ecto.Migration

  def change do
    alter table(:creator_videos) do
      add :thumbnail_storage_key, :string
    end
  end
end
