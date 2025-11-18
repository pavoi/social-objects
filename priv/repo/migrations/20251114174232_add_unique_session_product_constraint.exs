defmodule Pavoi.Repo.Migrations.AddUniqueSessionProductConstraint do
  use Ecto.Migration

  def change do
    drop_if_exists index(:session_products, [:session_id, :product_id],
                     name: :session_products_session_id_product_id_index
                   )

    create unique_index(:session_products, [:session_id, :product_id],
             name: :session_products_session_id_product_id_index
           )
  end
end
