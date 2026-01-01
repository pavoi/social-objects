defmodule Pavoi.Repo.Migrations.RemoveOutreachStatusFromCreators do
  use Ecto.Migration

  def change do
    alter table(:creators) do
      remove :outreach_status, :string
    end
  end
end
