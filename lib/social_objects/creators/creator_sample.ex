defmodule SocialObjects.Creators.CreatorSample do
  @moduledoc """
  Tracks products sampled to creators (free product orders).

  When a creator receives a free sample, this record captures the order details,
  product information, and delivery status.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type status :: :pending | :shipped | :delivered | :cancelled

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          creator_id: pos_integer() | nil,
          brand_id: pos_integer() | nil,
          product_id: pos_integer() | nil,
          tiktok_order_id: String.t() | nil,
          tiktok_sku_id: String.t() | nil,
          product_name: String.t() | nil,
          variation: String.t() | nil,
          quantity: integer(),
          ordered_at: DateTime.t() | nil,
          shipped_at: DateTime.t() | nil,
          delivered_at: DateTime.t() | nil,
          status: status() | nil,
          fulfilled: boolean(),
          fulfilled_at: DateTime.t() | nil,
          attributed_video_id: pos_integer() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  @statuses ~w(pending shipped delivered cancelled)a

  schema "creator_samples" do
    belongs_to :creator, SocialObjects.Creators.Creator
    belongs_to :brand, SocialObjects.Catalog.Brand
    belongs_to :product, SocialObjects.Catalog.Product

    # TikTok Order Info
    field :tiktok_order_id, :string
    field :tiktok_sku_id, :string
    field :product_name, :string
    field :variation, :string
    field :quantity, :integer, default: 1

    # Timing
    field :ordered_at, :utc_datetime
    field :shipped_at, :utc_datetime
    field :delivered_at, :utc_datetime

    # Status
    field :status, Ecto.Enum, values: @statuses

    # Fulfillment tracking - did creator post about this sample?
    field :fulfilled, :boolean, default: false
    field :fulfilled_at, :utc_datetime
    belongs_to :attributed_video, SocialObjects.Creators.CreatorVideo

    timestamps()
  end

  @doc false
  def changeset(creator_sample, attrs) do
    creator_sample
    |> cast(attrs, [
      :creator_id,
      :brand_id,
      :product_id,
      :tiktok_order_id,
      :tiktok_sku_id,
      :product_name,
      :variation,
      :quantity,
      :ordered_at,
      :shipped_at,
      :delivered_at,
      :status,
      :fulfilled,
      :fulfilled_at,
      :attributed_video_id
    ])
    |> validate_required([:creator_id, :brand_id])
    |> validate_number(:quantity, greater_than: 0)
    |> unique_constraint([:tiktok_order_id, :tiktok_sku_id])
    |> foreign_key_constraint(:creator_id)
    |> foreign_key_constraint(:brand_id)
    |> foreign_key_constraint(:product_id)
  end

  @doc """
  Returns the list of valid statuses.
  """
  def statuses, do: @statuses
end
