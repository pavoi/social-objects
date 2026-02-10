defmodule Pavoi.Repo.Migrations.AddTiktokPerformanceToProducts do
  use Ecto.Migration

  def change do
    alter table(:products) do
      add :gmv_cents, :integer, default: 0
      add :items_sold, :integer, default: 0
      add :orders, :integer, default: 0
      add :performance_synced_at, :utc_datetime
    end

    create index(:products, [:brand_id, :performance_synced_at])
  end
end
