defmodule Pavoi.Repo.Migrations.AddGmvHourlyToStreams do
  use Ecto.Migration

  def change do
    alter table(:tiktok_streams) do
      add :gmv_hourly, :map
    end
  end
end
