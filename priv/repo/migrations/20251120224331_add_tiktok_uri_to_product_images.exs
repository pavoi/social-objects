defmodule Pavoi.Repo.Migrations.AddTiktokUriToProductImages do
  use Ecto.Migration

  def change do
    alter table(:product_images) do
      add :tiktok_uri, :string
    end
  end
end
