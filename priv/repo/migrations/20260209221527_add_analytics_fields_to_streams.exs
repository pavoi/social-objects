defmodule Pavoi.Repo.Migrations.AddAnalyticsFieldsToStreams do
  use Ecto.Migration

  def change do
    alter table(:tiktok_streams) do
      add :tiktok_live_id, :string
      add :official_gmv_cents, :integer
      add :gmv_24h_cents, :integer
      add :avg_view_duration_seconds, :integer
      add :product_impressions, :integer
      add :product_clicks, :integer
      add :unique_customers, :integer
      add :conversion_rate, :decimal, precision: 5, scale: 2
      add :analytics_synced_at, :utc_datetime
    end

    create index(:tiktok_streams, [:analytics_synced_at, :ended_at])
  end
end
