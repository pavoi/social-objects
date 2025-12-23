defmodule Pavoi.Creators.Creator do
  @moduledoc """
  Represents a creator/affiliate in the CRM.

  Creators are TikTok Shop affiliates who receive product samples and create
  content promoting products. This is the central entity for tracking creator
  identity, contact information, and performance metrics.

  ## TikTok Badge Levels

  TikTok Shop has an official Creator Badge system based on monthly GMV:
  - bronze: Entry level
  - silver: $1K - $5K monthly GMV
  - gold: $5K+ monthly GMV
  - platinum, ruby, emerald, sapphire, diamond: Higher tiers
  """
  use Ecto.Schema
  import Ecto.Changeset

  @badge_levels ~w(bronze silver gold platinum ruby emerald sapphire diamond)
  @outreach_statuses ~w(pending approved sent skipped unsubscribed)

  schema "creators" do
    # Identity
    field :tiktok_username, :string
    field :tiktok_user_id, :string
    field :tiktok_profile_url, :string

    # Contact Info
    field :email, :string
    field :phone, :string
    field :phone_verified, :boolean, default: false
    field :first_name, :string
    field :last_name, :string

    # Address
    field :address_line_1, :string
    field :address_line_2, :string
    field :city, :string
    field :state, :string
    field :zipcode, :string
    field :country, :string, default: "US"

    # TikTok Shop Creator Badge
    field :tiktok_badge_level, :string

    # Internal classification
    field :is_whitelisted, :boolean, default: false
    field :notes, :string

    # Current metrics (cached from latest enrichment)
    field :follower_count, :integer
    field :total_gmv_cents, :integer, default: 0
    field :total_videos, :integer, default: 0
    field :video_gmv_cents, :integer, default: 0
    field :live_gmv_cents, :integer, default: 0
    field :avg_video_views, :integer
    field :video_count, :integer, default: 0
    field :live_count, :integer, default: 0

    # TikTok identity from marketplace API
    field :tiktok_nickname, :string
    field :tiktok_avatar_url, :string
    field :tiktok_bio, :string

    # Enrichment tracking
    field :last_enriched_at, :utc_datetime
    field :enrichment_source, :string

    # Outreach tracking
    field :outreach_status, :string
    field :outreach_sent_at, :utc_datetime
    field :sms_consent, :boolean, default: false
    field :sms_consent_at, :utc_datetime
    field :sms_consent_ip, :string
    field :sms_consent_user_agent, :string

    # Associations
    has_many :brand_creators, Pavoi.Creators.BrandCreator
    has_many :brands, through: [:brand_creators, :brand]
    has_many :creator_samples, Pavoi.Creators.CreatorSample
    has_many :creator_videos, Pavoi.Creators.CreatorVideo
    has_many :performance_snapshots, Pavoi.Creators.CreatorPerformanceSnapshot
    has_many :outreach_logs, Pavoi.Outreach.OutreachLog
    has_many :tag_assignments, Pavoi.Creators.CreatorTagAssignment
    many_to_many :creator_tags, Pavoi.Creators.CreatorTag, join_through: "creator_tag_assignments"
    has_many :purchases, Pavoi.Creators.CreatorPurchase

    timestamps()
  end

  @doc false
  def changeset(creator, attrs) do
    creator
    |> cast(attrs, [
      :tiktok_username,
      :tiktok_user_id,
      :tiktok_profile_url,
      :tiktok_nickname,
      :tiktok_avatar_url,
      :tiktok_bio,
      :email,
      :phone,
      :phone_verified,
      :first_name,
      :last_name,
      :address_line_1,
      :address_line_2,
      :city,
      :state,
      :zipcode,
      :country,
      :tiktok_badge_level,
      :is_whitelisted,
      :notes,
      :follower_count,
      :total_gmv_cents,
      :total_videos,
      :video_gmv_cents,
      :live_gmv_cents,
      :avg_video_views,
      :video_count,
      :live_count,
      :last_enriched_at,
      :enrichment_source,
      :outreach_status,
      :outreach_sent_at,
      :sms_consent,
      :sms_consent_at,
      :sms_consent_ip,
      :sms_consent_user_agent
    ])
    |> validate_required([])
    |> normalize_username()
    |> validate_inclusion(:tiktok_badge_level, @badge_levels,
      message: "must be a valid badge level"
    )
    |> validate_inclusion(:outreach_status, @outreach_statuses,
      message: "must be a valid outreach status"
    )
    |> validate_format(:email, ~r/@/, message: "must be a valid email")
    |> unique_constraint(:tiktok_username)
  end

  defp normalize_username(changeset) do
    case get_change(changeset, :tiktok_username) do
      nil -> changeset
      username -> put_change(changeset, :tiktok_username, String.downcase(String.trim(username)))
    end
  end

  @doc """
  Returns the list of valid TikTok badge levels.
  """
  def badge_levels, do: @badge_levels

  @doc """
  Returns the list of valid outreach statuses.
  """
  def outreach_statuses, do: @outreach_statuses

  @doc """
  Returns the creator's full name if available.
  """
  def full_name(%__MODULE__{first_name: first, last_name: last}) do
    [first, last]
    |> Enum.filter(&(&1 && &1 != ""))
    |> Enum.join(" ")
    |> case do
      "" -> nil
      name -> name
    end
  end
end
