defmodule SocialObjects.Creators.BrandCreator do
  @moduledoc """
  Junction table linking creators to brands they work with.

  Enables multi-brand support where a creator can work with multiple brands,
  and each brand-creator relationship can have its own status and notes.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type status :: :active | :inactive | :blocked
  @type last_touchpoint_type :: :email | :sms | :manual
  @type preferred_contact_channel :: :email | :sms | :tiktok_dm
  # Phase 1: Accept both old and new values during transition
  @type engagement_priority ::
          :high | :medium | :monitor | :rising_star | :vip_elite | :vip_stable | :vip_at_risk

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
          video_count: integer(),
          live_count: integer(),
          last_touchpoint_at: DateTime.t() | nil,
          last_touchpoint_type: last_touchpoint_type() | nil,
          preferred_contact_channel: preferred_contact_channel() | nil,
          next_touchpoint_at: DateTime.t() | nil,
          is_vip: boolean(),
          is_trending: boolean(),
          l30d_rank: integer() | nil,
          l90d_rank: integer() | nil,
          l30d_gmv_cents: integer() | nil,
          stability_score: integer() | nil,
          engagement_priority: engagement_priority() | nil,
          vip_locked: boolean(),
          unmatched_products_raw: String.t() | nil,
          gmv_seeded_externally: boolean(),
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  @statuses ~w(active inactive blocked)a
  @touchpoint_types ~w(email sms manual)a
  @preferred_contact_channels ~w(email sms tiktok_dm)a
  # Phase 1: Accept both old and new values during transition
  @engagement_priorities ~w(high medium monitor rising_star vip_elite vip_stable vip_at_risk)a

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

    # Brand-specific video/live counts (seeded from external imports or computed from creator_videos)
    field :video_count, :integer, default: 0
    field :live_count, :integer, default: 0

    field :last_touchpoint_at, :utc_datetime
    field :last_touchpoint_type, Ecto.Enum, values: @touchpoint_types
    field :preferred_contact_channel, Ecto.Enum, values: @preferred_contact_channels
    field :next_touchpoint_at, :utc_datetime

    field :is_vip, :boolean, default: false
    field :is_trending, :boolean, default: false
    field :l30d_rank, :integer
    field :l90d_rank, :integer
    field :l30d_gmv_cents, :integer
    field :stability_score, :integer
    field :engagement_priority, Ecto.Enum, values: @engagement_priorities
    field :vip_locked, :boolean, default: false

    # Fallback storage for unmatched product names from external imports
    field :unmatched_products_raw, :string

    # Bootstrap flag for GMV - prevents double-counting on first TikTok sync
    field :gmv_seeded_externally, :boolean, default: false

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
      :brand_gmv_last_synced_at,
      :video_count,
      :live_count,
      :last_touchpoint_at,
      :last_touchpoint_type,
      :preferred_contact_channel,
      :next_touchpoint_at,
      :is_vip,
      :is_trending,
      :l30d_rank,
      :l90d_rank,
      :l30d_gmv_cents,
      :stability_score,
      :engagement_priority,
      :vip_locked,
      :unmatched_products_raw,
      :gmv_seeded_externally
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

  @doc """
  Returns the list of valid touchpoint types.
  """
  def touchpoint_types, do: @touchpoint_types

  @doc """
  Returns the list of valid preferred contact channels.
  """
  def preferred_contact_channels, do: @preferred_contact_channels

  @doc """
  Returns the list of valid engagement priorities.
  """
  def engagement_priorities, do: @engagement_priorities
end
