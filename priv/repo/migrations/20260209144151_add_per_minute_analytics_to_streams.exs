defmodule Pavoi.Repo.Migrations.AddPerMinuteAnalyticsToStreams do
  use Ecto.Migration

  def change do
    alter table(:tiktok_streams) do
      # Per-minute time-series data from API
      add :analytics_per_minute, :map

      # Additional fields we're not yet capturing
      add :total_views, :integer
      add :items_sold, :integer
      add :click_through_rate, :decimal, precision: 5, scale: 2
    end
  end
end
