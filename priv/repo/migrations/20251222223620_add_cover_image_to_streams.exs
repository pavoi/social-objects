defmodule Pavoi.Repo.Migrations.AddCoverImageToStreams do
  use Ecto.Migration

  def change do
    alter table(:tiktok_streams) do
      add :cover_image_url, :string
    end
  end
end
