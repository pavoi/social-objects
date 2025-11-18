defmodule Pavoi.Repo.Migrations.CreateSessionProducts do
  use Ecto.Migration

  def change do
    create table(:session_products) do
      add :session_id, references(:sessions, on_delete: :delete_all), null: false
      add :product_id, references(:products, on_delete: :restrict), null: false
      add :position, :integer, null: false
      add :section, :string, size: 255
      add :featured_name, :string, size: 500
      add :featured_talking_points_md, :text
      add :featured_original_price_cents, :integer
      add :featured_sale_price_cents, :integer
      add :notes, :text

      timestamps()
    end

    create index(:session_products, [:session_id])
    create index(:session_products, [:product_id])
    create unique_index(:session_products, [:session_id, :position])
    create index(:session_products, [:session_id, :product_id])
  end
end
