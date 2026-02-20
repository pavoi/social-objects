defmodule SocialObjects.Repo.Migrations.RemoveTiktokBadgeLevel do
  use Ecto.Migration

  def change do
    alter table(:creators) do
      remove :tiktok_badge_level, :string
    end
  end
end
