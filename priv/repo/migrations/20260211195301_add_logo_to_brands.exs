defmodule SocialObjects.Repo.Migrations.AddLogoToBrands do
  use Ecto.Migration

  def change do
    alter table(:brands) do
      add :logo_url, :string
    end
  end
end
