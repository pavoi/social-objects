defmodule Pavoi.Creators.CreatorPurchase do
  @moduledoc """
  Tracks orders placed BY creators (where creator is the buyer).

  This helps measure sample ROI by identifying when creators who received
  free samples later purchase products themselves. When a creator buys
  a product they previously sampled, it indicates strong product affinity.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "creator_purchases" do
    belongs_to :creator, Pavoi.Creators.Creator

    # TikTok Order Info
    field :tiktok_order_id, :string
    field :order_status, :string
    field :ordered_at, :utc_datetime

    # Money
    field :total_amount_cents, :integer, default: 0
    field :currency, :string, default: "USD"

    # Product Info (array of maps with product_id, product_name, sku_id, quantity, sale_price_cents)
    field :line_items, {:array, :map}, default: []

    # Flags
    field :is_sample_order, :boolean, default: false

    timestamps()
  end

  @doc false
  def changeset(purchase, attrs) do
    purchase
    |> cast(attrs, [
      :creator_id,
      :tiktok_order_id,
      :order_status,
      :ordered_at,
      :total_amount_cents,
      :currency,
      :line_items,
      :is_sample_order
    ])
    |> validate_required([:creator_id, :tiktok_order_id])
    |> unique_constraint(:tiktok_order_id)
    |> foreign_key_constraint(:creator_id)
  end
end
