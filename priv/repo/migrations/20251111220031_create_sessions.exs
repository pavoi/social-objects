defmodule Pavoi.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  def change do
    create table(:sessions) do
      add :name, :string, size: 500, null: false
      add :slug, :string, size: 255, null: false
      add :brand_id, references(:brands, on_delete: :restrict), null: false
      add :scheduled_at, :naive_datetime
      add :duration_minutes, :integer
      add :notes, :text
      add :status, :string, size: 50, null: false, default: "draft"

      timestamps()
    end

    create unique_index(:sessions, [:slug])
    create index(:sessions, [:brand_id])
    create index(:sessions, [:status])
    create index(:sessions, [:scheduled_at])
  end
end
