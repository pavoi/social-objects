defmodule SocialObjects.Repo.Migrations.AddSampleCountToProducts do
  use Ecto.Migration

  def change do
    alter table(:products) do
      add :sample_count, :integer, null: false, default: 0
      add :sample_count_synced_at, :utc_datetime
    end

    # Non-negative constraint
    create constraint(:products, :sample_count_non_negative, check: "sample_count >= 0")

    # Index for sorting by sample_count within a brand
    create index(:products, [:brand_id, :sample_count])
  end
end
