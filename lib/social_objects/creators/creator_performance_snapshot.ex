defmodule SocialObjects.Creators.CreatorPerformanceSnapshot do
  @moduledoc """
  Point-in-time snapshots of creator performance metrics.

  Enables historical tracking of creator performance over time,
  with data sourced from various platforms like Refunnel or TikTok API.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          brand_id: pos_integer() | nil,
          creator_id: pos_integer() | nil,
          snapshot_date: Date.t() | nil,
          source: String.t() | nil,
          follower_count: integer() | nil,
          gmv_cents: integer() | nil,
          video_gmv_cents: integer() | nil,
          live_gmv_cents: integer() | nil,
          avg_video_views: integer() | nil,
          emv_cents: integer() | nil,
          total_posts: integer() | nil,
          total_likes: integer() | nil,
          total_comments: integer() | nil,
          total_shares: integer() | nil,
          total_impressions: integer() | nil,
          engagement_count: integer() | nil,
          gmv_delta_cents: integer() | nil,
          video_gmv_delta_cents: integer() | nil,
          live_gmv_delta_cents: integer() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  @sources ~w(refunnel tiktok_api tiktok_marketplace manual csv_import brand_gmv)

  schema "creator_performance_snapshots" do
    belongs_to :brand, SocialObjects.Catalog.Brand
    belongs_to :creator, SocialObjects.Creators.Creator

    field :snapshot_date, :date
    field :source, :string

    # Metrics
    field :follower_count, :integer
    field :gmv_cents, :integer
    field :video_gmv_cents, :integer
    field :live_gmv_cents, :integer
    field :avg_video_views, :integer
    field :emv_cents, :integer
    field :total_posts, :integer
    field :total_likes, :integer
    field :total_comments, :integer
    field :total_shares, :integer
    field :total_impressions, :integer
    field :engagement_count, :integer

    # Delta tracking for cumulative GMV calculation
    field :gmv_delta_cents, :integer
    field :video_gmv_delta_cents, :integer
    field :live_gmv_delta_cents, :integer

    timestamps()
  end

  @doc false
  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :creator_id,
      :snapshot_date,
      :source,
      :follower_count,
      :gmv_cents,
      :video_gmv_cents,
      :live_gmv_cents,
      :avg_video_views,
      :emv_cents,
      :total_posts,
      :total_likes,
      :total_comments,
      :total_shares,
      :total_impressions,
      :engagement_count,
      :gmv_delta_cents,
      :video_gmv_delta_cents,
      :live_gmv_delta_cents
    ])
    |> validate_required([:brand_id, :creator_id, :snapshot_date])
    |> validate_inclusion(:source, @sources)
    |> unique_constraint([:creator_id, :snapshot_date, :source])
    |> foreign_key_constraint(:creator_id)
    |> foreign_key_constraint(:brand_id)
  end

  @doc """
  Returns the list of valid sources.
  """
  def sources, do: @sources
end
