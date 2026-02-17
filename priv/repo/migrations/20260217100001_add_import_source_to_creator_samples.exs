defmodule SocialObjects.Repo.Migrations.AddImportSourceToCreatorSamples do
  use Ecto.Migration

  def change do
    alter table(:creator_samples) do
      # Source of the import (e.g., "euka", "tiktok")
      add :import_source, :string

      # Unique key within source for deduplication (e.g., "{handle}:{md5_first_8_of_product_name}")
      add :import_source_key, :string
    end

    # Unique index for external imports to prevent duplicates on re-run
    create unique_index(
             :creator_samples,
             [:creator_id, :brand_id, :import_source, :import_source_key],
             name: :creator_samples_external_import_unique,
             where: "import_source IS NOT NULL AND import_source_key IS NOT NULL"
           )

    # DB integrity constraint: import_source and import_source_key must be both null or both non-null
    create constraint(:creator_samples, :import_metadata_consistency,
             check:
               "(import_source IS NULL AND import_source_key IS NULL) OR (import_source IS NOT NULL AND import_source_key IS NOT NULL)"
           )
  end
end
