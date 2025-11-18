defmodule Hudson.LocalRepo.Migrations.CreateSyncOperations do
  use Ecto.Migration

  def change do
    create table(:sync_operations) do
      add :action, :string, null: false
      add :payload, :map
      add :status, :string, default: "pending", null: false
      add :attempts, :integer, default: 0, null: false
      add :last_error, :string

      timestamps(type: :utc_datetime)
    end

    create index(:sync_operations, [:status])
    create index(:sync_operations, [:inserted_at])
  end
end
