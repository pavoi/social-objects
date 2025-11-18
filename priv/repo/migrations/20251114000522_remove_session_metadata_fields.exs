defmodule Pavoi.Repo.Migrations.RemoveSessionMetadataFields do
  use Ecto.Migration

  def change do
    # Drop indexes first
    drop_if_exists index(:sessions, [:status])
    drop_if_exists index(:sessions, [:scheduled_at])

    # Remove columns
    alter table(:sessions) do
      remove :status, :string
      remove :scheduled_at, :naive_datetime
      remove :duration_minutes, :integer
    end
  end
end
