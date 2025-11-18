defmodule Pavoi.Repo.Migrations.CreateProducts do
  use Ecto.Migration

  def change do
    create table(:products) do
      add :brand_id, references(:brands, on_delete: :restrict), null: false
      add :display_number, :integer
      add :name, :string, size: 500, null: false
      add :short_name, :string, size: 100
      add :description, :text
      add :talking_points_md, :text
      add :original_price_cents, :integer, null: false
      add :sale_price_cents, :integer
      add :pid, :string, size: 100
      add :sku, :string, size: 100
      add :stock, :integer
      add :is_featured, :boolean, default: false, null: false
      add :tags, {:array, :string}, default: []
      add :external_url, :string, size: 500

      timestamps()
    end

    create index(:products, [:brand_id])
    create unique_index(:products, [:pid], where: "pid IS NOT NULL")
    create index(:products, [:sku])
    create index(:products, [:tags], using: :gin)
  end
end
