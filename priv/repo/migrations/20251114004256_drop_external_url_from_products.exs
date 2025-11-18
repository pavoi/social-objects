defmodule Pavoi.Repo.Migrations.DropExternalUrlFromProducts do
  use Ecto.Migration

  def change do
    alter table(:products) do
      remove :external_url
    end
  end
end
