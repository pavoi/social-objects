defmodule Pavoi.Repo.Migrations.AddGmvToStreams do
  use Ecto.Migration

  def change do
    alter table(:tiktok_streams) do
      add :gmv_cents, :integer
      add :gmv_order_count, :integer
    end
  end
end
