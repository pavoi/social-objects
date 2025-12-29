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
    field :raw_metadata, :map, default: %{}
    field :cover_image_key, :string
    field :gmv_cents, :integer
    field :gmv_order_count, :integer
    field :gmv_hourly, :map

    has_many :comments, Pavoi.TiktokLive.Comment, foreign_key: :stream_id
    has_many :stats, Pavoi.TiktokLive.StreamStat, foreign_key: :stream_id
    has_many :stream_products, Pavoi.TiktokLive.StreamProduct, foreign_key: :stream_id
    has_many :session_streams, Pavoi.TiktokLive.SessionStream, foreign_key: :stream_id
    has_many :sessions, through: [:session_streams, :session]

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
      :raw_metadata,
      :cover_image_key,
      :gmv_cents,
      :gmv_order_count,
      :gmv_hourly
    ])
    |> validate_required([:room_id, :unique_id, :started_at])
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
