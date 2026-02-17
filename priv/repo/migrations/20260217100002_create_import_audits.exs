defmodule SocialObjects.Repo.Migrations.CreateImportAudits do
  use Ecto.Migration

  def change do
    create table(:import_audits) do
      add :brand_id, references(:brands, on_delete: :delete_all), null: false
      # "euka", "tiktok", etc.
      add :source, :string, null: false
      # Original file path
      add :file_path, :string
      # MD5/SHA of file for deduplication
      add :file_checksum, :string
      # pending, running, completed, failed
      add :status, :string, null: false, default: "pending"
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime

      # Counts
      add :rows_processed, :integer, default: 0
      add :creators_created, :integer, default: 0
      add :creators_updated, :integer, default: 0
      add :samples_created, :integer, default: 0
      add :error_count, :integer, default: 0

      # Error details (first N errors for debugging)
      add :errors_sample, :map

      timestamps()
    end

    create index(:import_audits, [:brand_id])
    create index(:import_audits, [:source])
    create index(:import_audits, [:file_checksum])

    # Prevent accidental same-file reruns
    create unique_index(:import_audits, [:brand_id, :source, :file_checksum],
             name: :import_audits_no_duplicate_runs,
             where: "status IN ('running', 'completed')"
           )
  end
end
