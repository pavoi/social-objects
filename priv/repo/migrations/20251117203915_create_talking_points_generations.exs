defmodule Pavoi.Repo.Migrations.CreateTalkingPointsGenerations do
  use Ecto.Migration

  def change do
    create table(:talking_points_generations) do
      add :job_id, :string, null: false
      add :session_id, references(:sessions, on_delete: :delete_all)
      add :product_ids, {:array, :integer}, null: false, default: []
      add :status, :string, null: false, default: "pending"
      add :total_count, :integer, null: false
      add :completed_count, :integer, null: false, default: 0
      add :failed_count, :integer, null: false, default: 0
      add :results, :map, null: false, default: %{}
      add :errors, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:talking_points_generations, [:job_id])
    create index(:talking_points_generations, [:session_id])
    create index(:talking_points_generations, [:status])
  end
end
