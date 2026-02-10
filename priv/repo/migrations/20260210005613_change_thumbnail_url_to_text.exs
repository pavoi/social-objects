defmodule Pavoi.Repo.Migrations.ChangeThumbnailUrlToText do
  use Ecto.Migration

  def change do
    alter table(:creator_videos) do
      modify :thumbnail_url, :text, from: :string
    end
  end
end
