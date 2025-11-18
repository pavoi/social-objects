defmodule Pavoi.Repo.Migrations.CreateProductVariants do
  use Ecto.Migration

  def change do
    create table(:product_variants) do
      add :product_id, references(:products, on_delete: :delete_all), null: false
      add :shopify_variant_id, :string, null: false
      add :title, :string, null: false
      add :sku, :string
      add :price_cents, :integer, null: false
      add :compare_at_price_cents, :integer
      add :barcode, :string
      add :position, :integer, default: 0, null: false
      add :selected_options, :map, default: %{}, null: false

      timestamps()
    end

    create index(:product_variants, [:product_id])
    create unique_index(:product_variants, [:shopify_variant_id])
    create index(:product_variants, [:sku])

    # Clear talking_points_md since it was incorrectly storing variant data
    execute "UPDATE products SET talking_points_md = NULL", ""
  end
end
