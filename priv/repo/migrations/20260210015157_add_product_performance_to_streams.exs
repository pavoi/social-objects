defmodule Pavoi.Repo.Migrations.AddProductPerformanceToStreams do
  use Ecto.Migration

  def change do
    alter table(:tiktok_streams) do
      add :product_performance, :map
    end
  end
end
