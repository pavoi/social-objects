defmodule Pavoi.TiktokLive.Stream do
  @moduledoc """
  Represents a TikTok live stream session that has been captured.

  Each stream record tracks metadata about the live broadcast including
  engagement metrics and timing information.
  """
  use Ecto.Schema
  import Ecto.Changeset

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

    belongs_to :brand, Pavoi.Catalog.Brand
    belongs_to :product_set, Pavoi.ProductSets.ProductSet

    has_many :comments, Pavoi.TiktokLive.Comment, foreign_key: :stream_id
    has_many :stats, Pavoi.TiktokLive.StreamStat, foreign_key: :stream_id
    has_many :stream_products, Pavoi.TiktokLive.StreamProduct, foreign_key: :stream_id
    has_many :product_set_streams, Pavoi.TiktokLive.ProductSetStream, foreign_key: :stream_id
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
  def cover_image_url(%__MODULE__{cover_image_key: key}), do: Pavoi.Storage.public_url(key)

  @doc """
  Returns the list of valid stream statuses.
  """
  def statuses, do: @statuses
end
