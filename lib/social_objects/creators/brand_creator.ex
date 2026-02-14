defmodule SocialObjects.Creators.BrandCreator do
  @moduledoc """
  Junction table linking creators to brands they work with.

  Enables multi-brand support where a creator can work with multiple brands,
  and each brand-creator relationship can have its own status and notes.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type status :: :active | :inactive | :blocked

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          brand_id: pos_integer() | nil,
          creator_id: pos_integer() | nil,
          status: status(),
          joined_at: DateTime.t() | nil,
          notes: String.t() | nil,
          brand_gmv_cents: integer(),
          brand_video_gmv_cents: integer(),
          brand_live_gmv_cents: integer(),
          cumulative_brand_gmv_cents: integer(),
          cumulative_brand_video_gmv_cents: integer(),
          cumulative_brand_live_gmv_cents: integer(),
          brand_gmv_tracking_started_at: Date.t() | nil,
          brand_gmv_last_synced_at: DateTime.t() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  @statuses ~w(active inactive blocked)a

  schema "brand_creators" do
    belongs_to :brand, SocialObjects.Catalog.Brand
    belongs_to :creator, SocialObjects.Creators.Creator

    field :status, Ecto.Enum, values: @statuses, default: :active
    field :joined_at, :utc_datetime
    field :notes, :string

    # Rolling 30-day GMV from video/live analytics (brand-specific)
    field :brand_gmv_cents, :integer, default: 0
    field :brand_video_gmv_cents, :integer, default: 0
    field :brand_live_gmv_cents, :integer, default: 0

    # Cumulative GMV (delta-accumulated, brand-specific)
    field :cumulative_brand_gmv_cents, :integer, default: 0
    field :cumulative_brand_video_gmv_cents, :integer, default: 0
    field :cumulative_brand_live_gmv_cents, :integer, default: 0

    # Tracking metadata
    field :brand_gmv_tracking_started_at, :date
    field :brand_gmv_last_synced_at, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(brand_creator, attrs) do
    brand_creator
    |> cast(attrs, [
      :brand_id,
      :creator_id,
      :status,
      :joined_at,
      :notes,
      :brand_gmv_cents,
      :brand_video_gmv_cents,
      :brand_live_gmv_cents,
      :cumulative_brand_gmv_cents,
      :cumulative_brand_video_gmv_cents,
      :cumulative_brand_live_gmv_cents,
      :brand_gmv_tracking_started_at,
      :brand_gmv_last_synced_at
    ])
    |> validate_required([:brand_id, :creator_id])
    |> unique_constraint([:brand_id, :creator_id])
    |> foreign_key_constraint(:brand_id)
    |> foreign_key_constraint(:creator_id)
  end

  @doc """
  Returns the list of valid statuses.
  """
  def statuses, do: @statuses
end
