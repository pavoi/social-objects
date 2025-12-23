defmodule Pavoi.Repo.Migrations.CreateCreatorPurchases do
  use Ecto.Migration

  @moduledoc """
  Creates the creator_purchases table to track orders placed BY creators.

  This helps measure sample ROI by identifying when creators who received
  free samples later purchase products themselves.
  """

  def change do
    create table(:creator_purchases) do
      add :creator_id, references(:creators, on_delete: :delete_all), null: false

      # TikTok Order Info
      add :tiktok_order_id, :string, null: false
      add :order_status, :string
      add :ordered_at, :utc_datetime

      # Money
      add :total_amount_cents, :integer, default: 0
      add :currency, :string, default: "USD"

      # Product Info (JSONB array for flexibility)
      add :line_items, {:array, :map}, default: []

      # Flags
      add :is_sample_order, :boolean, default: false

      timestamps()
    end

    create unique_index(:creator_purchases, [:tiktok_order_id])
    create index(:creator_purchases, [:creator_id])
    create index(:creator_purchases, [:ordered_at])
    create index(:creator_purchases, [:is_sample_order])
  end
end
