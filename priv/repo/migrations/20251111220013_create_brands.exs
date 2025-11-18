defmodule Pavoi.Repo.Migrations.CreateBrands do
  use Ecto.Migration

  def change do
    create table(:brands) do
      add :name, :string, size: 255, null: false
      add :slug, :string, size: 255, null: false
      add :notes, :text

      timestamps()
    end

    create unique_index(:brands, [:name])
    create unique_index(:brands, [:slug])
  end
end
