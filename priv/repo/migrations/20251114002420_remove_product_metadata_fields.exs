defmodule Pavoi.Repo.Migrations.RemoveProductMetadataFields do
  use Ecto.Migration

  def change do
    # Drop GIN index first
    drop_if_exists index(:products, [:tags], using: :gin)

    # Remove columns
    alter table(:products) do
      remove :tags, {:array, :string}
      remove :is_featured, :boolean
      remove :stock, :integer
      remove :short_name, :string
      remove :display_number, :integer
    end
  end
end
