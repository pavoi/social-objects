defmodule Pavoi.Repo.Migrations.CreateProductImages do
  use Ecto.Migration

  def change do
    create table(:product_images) do
      add :product_id, references(:products, on_delete: :delete_all), null: false
      add :position, :integer, null: false, default: 0
      add :path, :string, size: 1000, null: false
      add :thumbnail_path, :string, size: 1000
      add :alt_text, :string, size: 500
      add :is_primary, :boolean, default: false, null: false

      timestamps()
    end

    create index(:product_images, [:product_id])
    create index(:product_images, [:product_id, :position])

    create unique_index(:product_images, [:product_id],
             where: "is_primary = true",
             name: :product_images_one_primary_per_product
           )
  end
end
