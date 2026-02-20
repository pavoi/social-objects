defmodule SocialObjects.Creators.CreatorVideo do
  @moduledoc """
  Tracks video content created by creators.

  Stores canonical creator video records plus best-known all-time metrics.

  Note: `gmv_cents`, `items_sold`, `impressions`, and similar cumulative
  metrics are maintained as monotonic all-time caches from sync runs.
  Period-specific (30/90 day) values are stored separately in
  `creator_video_metric_snapshots`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          brand_id: pos_integer() | nil,
          creator_id: pos_integer() | nil,
          tiktok_video_id: String.t() | nil,
          video_url: String.t() | nil,
          title: String.t() | nil,
          posted_at: DateTime.t() | nil,
          gmv_cents: integer(),
          items_sold: integer(),
          affiliate_orders: integer(),
          impressions: integer(),
          likes: integer(),
          comments: integer(),
          shares: integer(),
          ctr: Decimal.t() | nil,
          est_commission_cents: integer() | nil,
          gpm_cents: integer() | nil,
          duration: integer() | nil,
          hash_tags: [String.t()],
          thumbnail_url: String.t() | nil,
          thumbnail_storage_key: String.t() | nil,
          attributed_sample_id: pos_integer() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  schema "creator_videos" do
    belongs_to :brand, SocialObjects.Catalog.Brand
    belongs_to :creator, SocialObjects.Creators.Creator

    # Video Identity
    field :tiktok_video_id, :string
    field :video_url, :string
    field :title, :string

    # Timing
    field :posted_at, :utc_datetime

    # Performance Metrics
    field :gmv_cents, :integer, default: 0
    field :items_sold, :integer, default: 0
    field :affiliate_orders, :integer, default: 0
    field :impressions, :integer, default: 0
    field :likes, :integer, default: 0
    field :comments, :integer, default: 0
    field :shares, :integer, default: 0
    field :ctr, :decimal

    # Commission
    field :est_commission_cents, :integer

    # Additional performance metrics from Analytics API
    field :gpm_cents, :integer
    field :duration, :integer
    field :hash_tags, {:array, :string}, default: []

    # Thumbnail for embed display
    field :thumbnail_url, :string
    field :thumbnail_storage_key, :string

    # Sample fulfillment - which sample this video fulfilled
    belongs_to :attributed_sample, SocialObjects.Creators.CreatorSample

    # Associations
    has_many :video_products, SocialObjects.Creators.CreatorVideoProduct

    timestamps()
  end

  @doc false
  def changeset(creator_video, attrs) do
    creator_video
    |> cast(attrs, [
      :creator_id,
      :tiktok_video_id,
      :video_url,
      :title,
      :posted_at,
      :gmv_cents,
      :items_sold,
      :affiliate_orders,
      :impressions,
      :likes,
      :comments,
      :shares,
      :ctr,
      :est_commission_cents,
      :attributed_sample_id,
      :gpm_cents,
      :duration,
      :hash_tags,
      :thumbnail_url,
      :thumbnail_storage_key
    ])
    |> validate_required([:brand_id, :creator_id, :tiktok_video_id])
    |> unique_constraint(:tiktok_video_id)
    |> foreign_key_constraint(:creator_id)
    |> foreign_key_constraint(:brand_id)
  end
end
