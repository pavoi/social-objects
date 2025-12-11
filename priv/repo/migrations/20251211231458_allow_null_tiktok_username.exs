defmodule Pavoi.Repo.Migrations.AllowNullTiktokUsername do
  use Ecto.Migration

  def change do
    alter table(:creators) do
      modify :tiktok_username, :string, null: true, from: {:string, null: false}
    end
  end
end
