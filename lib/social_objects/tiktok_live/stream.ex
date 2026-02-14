defmodule SocialObjects.TiktokLive.Stream do
  @moduledoc """
  Represents a TikTok live stream session that has been captured.

  Each stream record tracks metadata about the live broadcast including
  engagement metrics and timing information.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type status :: :capturing | :ended | :failed

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          room_id: String.t() | nil,
          unique_id: String.t() | nil,
          title: String.t() | nil,
          started_at: DateTime.t() | nil,
          ended_at: DateTime.t() | nil,
          status: status(),
          viewer_count_current: integer(),
          viewer_count_peak: integer(),
          total_likes: integer(),
          total_comments: integer(),
          total_gifts_value: integer(),
          total_follows: integer(),
          total_shares: integer(),
          raw_metadata: map(),
          cover_image_key: String.t() | nil,
          gmv_cents: integer() | nil,
          gmv_order_count: integer() | nil,
          gmv_hourly: map() | nil,
          report_sent_at: DateTime.t() | nil,
          sentiment_analysis: String.t() | nil,
          tiktok_live_id: String.t() | nil,
          official_gmv_cents: integer() | nil,
          gmv_24h_cents: integer() | nil,
          avg_view_duration_seconds: integer() | nil,
          product_impressions: integer() | nil,
          product_clicks: integer() | nil,
          unique_customers: integer() | nil,
          conversion_rate: Decimal.t() | nil,
          analytics_synced_at: DateTime.t() | nil,
          analytics_per_minute: map() | nil,
          total_views: integer() | nil,
          items_sold: integer() | nil,
          click_through_rate: Decimal.t() | nil,
          product_performance: map() | nil,
          brand_id: pos_integer() | nil,
          product_set_id: pos_integer() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  @statuses ~w(capturing ended failed)a

  schema "tiktok_streams" do
    field :room_id, :string
    field :unique_id, :string
    field :title, :string
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime
    field :status, Ecto.Enum, values: @statuses, default: :capturing
    field :viewer_count_current, :integer, default: 0
    field :viewer_count_peak, :integer, default: 0
    field :total_likes, :integer, default: 0
    field :total_comments, :integer, default: 0
    field :total_gifts_value, :integer, default: 0
    field :total_follows, :integer, default: 0
    field :total_shares, :integer, default: 0
    field :raw_metadata, :map, default: %{}
    field :cover_image_key, :string
    field :gmv_cents, :integer
    field :gmv_order_count, :integer
    field :gmv_hourly, :map
    field :report_sent_at, :utc_datetime
    field :sentiment_analysis, :string

    # TikTok Shop Analytics API fields
    field :tiktok_live_id, :string
    field :official_gmv_cents, :integer
    field :gmv_24h_cents, :integer
    field :avg_view_duration_seconds, :integer
    field :product_impressions, :integer
    field :product_clicks, :integer
    field :unique_customers, :integer
    field :conversion_rate, :decimal
    field :analytics_synced_at, :utc_datetime

    # Per-minute time-series data and additional metrics
    field :analytics_per_minute, :map
    field :total_views, :integer
    field :items_sold, :integer
    field :click_through_rate, :decimal

    # Per-product performance data from Analytics API
    field :product_performance, :map

    belongs_to :brand, SocialObjects.Catalog.Brand
    belongs_to :product_set, SocialObjects.ProductSets.ProductSet

    has_many :comments, SocialObjects.TiktokLive.Comment, foreign_key: :stream_id
    has_many :stats, SocialObjects.TiktokLive.StreamStat, foreign_key: :stream_id
    has_many :stream_products, SocialObjects.TiktokLive.StreamProduct, foreign_key: :stream_id

    has_many :product_set_streams, SocialObjects.TiktokLive.ProductSetStream,
      foreign_key: :stream_id

    has_many :product_sets, through: [:product_set_streams, :product_set]

    timestamps()
  end

  @doc false
  def changeset(stream, attrs) do
    stream
    |> cast(attrs, [
      :room_id,
      :unique_id,
      :title,
      :started_at,
      :ended_at,
      :status,
      :viewer_count_current,
      :viewer_count_peak,
      :total_likes,
      :total_comments,
      :total_gifts_value,
      :total_follows,
      :total_shares,
      :raw_metadata,
      :cover_image_key,
      :gmv_cents,
      :gmv_order_count,
      :gmv_hourly,
      :product_set_id,
      :sentiment_analysis,
      :tiktok_live_id,
      :official_gmv_cents,
      :gmv_24h_cents,
      :avg_view_duration_seconds,
      :product_impressions,
      :product_clicks,
      :unique_customers,
      :conversion_rate,
      :analytics_synced_at,
      :analytics_per_minute,
      :total_views,
      :items_sold,
      :click_through_rate,
      :product_performance
    ])
    |> validate_required([:brand_id, :room_id, :unique_id, :started_at])
    |> foreign_key_constraint(:product_set_id)
    |> foreign_key_constraint(:brand_id)
  end

  @doc """
  Returns a presigned URL for the cover image, or nil if no cover image is stored.

  URLs are valid for 7 days and are generated on demand to avoid expiration issues.
  """
  def cover_image_url(%__MODULE__{cover_image_key: nil}), do: nil

  def cover_image_url(%__MODULE__{cover_image_key: key}),
    do: SocialObjects.Storage.public_url(key)

  @doc """
  Returns the list of valid stream statuses.
  """
  def statuses, do: @statuses
end
