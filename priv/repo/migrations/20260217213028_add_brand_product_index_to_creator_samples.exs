defmodule SocialObjects.Repo.Migrations.AddBrandProductIndexToCreatorSamples do
  use Ecto.Migration

  def change do
    # Composite index for efficient brand+product queries (counting samples per product)
    create index(:creator_samples, [:brand_id, :product_id])
  end
end
