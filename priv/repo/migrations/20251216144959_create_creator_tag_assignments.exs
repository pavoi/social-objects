defmodule Pavoi.Repo.Migrations.CreateCreatorTagAssignments do
  use Ecto.Migration

  def change do
    create table(:creator_tag_assignments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :creator_id, references(:creators, on_delete: :delete_all), null: false

      add :creator_tag_id, references(:creator_tags, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    # Prevent duplicate assignments
    create unique_index(:creator_tag_assignments, [:creator_id, :creator_tag_id])
    create index(:creator_tag_assignments, [:creator_id])
    create index(:creator_tag_assignments, [:creator_tag_id])
  end
end
