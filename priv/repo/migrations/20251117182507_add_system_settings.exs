defmodule Pavoi.Repo.Migrations.AddSystemSettings do
  use Ecto.Migration

  def change do
    create table(:system_settings) do
      add :key, :string, null: false
      add :value, :text
      add :value_type, :string, default: "string"

      timestamps()
    end

    create unique_index(:system_settings, [:key])

    # Insert initial shopify_last_sync_at setting
    execute(
      "INSERT INTO system_settings (key, value, value_type, inserted_at, updated_at) VALUES ('shopify_last_sync_at', NULL, 'datetime', NOW(), NOW())",
      "DELETE FROM system_settings WHERE key = 'shopify_last_sync_at'"
    )
  end
end
