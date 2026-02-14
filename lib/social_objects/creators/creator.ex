defmodule SocialObjects.Creators.Creator do
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

  @type badge_level ::
          :bronze | :silver | :gold | :platinum | :ruby | :emerald | :sapphire | :diamond

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          tiktok_username: String.t() | nil,
          tiktok_user_id: String.t() | nil,
          tiktok_profile_url: String.t() | nil,
          previous_tiktok_usernames: [String.t()],
          email: String.t() | nil,
          phone: String.t() | nil,
          phone_verified: boolean(),
          first_name: String.t() | nil,
          last_name: String.t() | nil,
          address_line_1: String.t() | nil,
          address_line_2: String.t() | nil,
          city: String.t() | nil,
          state: String.t() | nil,
          zipcode: String.t() | nil,
          country: String.t(),
          tiktok_badge_level: badge_level() | nil,
          is_whitelisted: boolean(),
          notes: String.t() | nil,
          follower_count: integer() | nil,
          total_gmv_cents: integer(),
          total_videos: integer(),
          video_gmv_cents: integer(),
          live_gmv_cents: integer(),
          avg_video_views: integer() | nil,
          video_count: integer(),
          live_count: integer(),
          cumulative_gmv_cents: integer(),
          cumulative_video_gmv_cents: integer(),
          cumulative_live_gmv_cents: integer(),
          gmv_tracking_started_at: Date.t() | nil,
          tiktok_nickname: String.t() | nil,
          tiktok_avatar_url: String.t() | nil,
          tiktok_avatar_storage_key: String.t() | nil,
          tiktok_bio: String.t() | nil,
          last_enriched_at: DateTime.t() | nil,
          enrichment_source: String.t() | nil,
          outreach_sent_at: DateTime.t() | nil,
          sms_consent: boolean(),
          sms_consent_at: DateTime.t() | nil,
          sms_consent_ip: String.t() | nil,
          sms_consent_user_agent: String.t() | nil,
          email_opted_out: boolean(),
          email_opted_out_at: DateTime.t() | nil,
          email_opted_out_reason: String.t() | nil,
          manually_edited_fields: [String.t()],
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  @badge_levels ~w(bronze silver gold platinum ruby emerald sapphire diamond)a

  schema "creators" do
    # Identity
    field :tiktok_username, :string
    field :tiktok_user_id, :string
    field :tiktok_profile_url, :string
    field :previous_tiktok_usernames, {:array, :string}, default: []

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
    field :tiktok_badge_level, Ecto.Enum, values: @badge_levels

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

    # Cumulative GMV tracking (accumulates deltas to handle TikTok's 30-day rolling window)
    field :cumulative_gmv_cents, :integer, default: 0
    field :cumulative_video_gmv_cents, :integer, default: 0
    field :cumulative_live_gmv_cents, :integer, default: 0
    field :gmv_tracking_started_at, :date

    # TikTok identity from marketplace API
    field :tiktok_nickname, :string
    field :tiktok_avatar_url, :string
    field :tiktok_avatar_storage_key, :string
    field :tiktok_bio, :string

    # Enrichment tracking
    field :last_enriched_at, :utc_datetime
    field :enrichment_source, :string

    # Outreach tracking
    field :outreach_sent_at, :utc_datetime
    field :sms_consent, :boolean, default: false
    field :sms_consent_at, :utc_datetime
    field :sms_consent_ip, :string
    field :sms_consent_user_agent, :string

    # Email opt-out (event-driven from webhooks)
    field :email_opted_out, :boolean, default: false
    field :email_opted_out_at, :utc_datetime
    field :email_opted_out_reason, :string

    # Associations
    has_many :brand_creators, SocialObjects.Creators.BrandCreator
    has_many :brands, through: [:brand_creators, :brand]
    has_many :creator_samples, SocialObjects.Creators.CreatorSample
    has_many :creator_videos, SocialObjects.Creators.CreatorVideo
    has_many :performance_snapshots, SocialObjects.Creators.CreatorPerformanceSnapshot
    has_many :outreach_logs, SocialObjects.Outreach.OutreachLog
    has_many :tag_assignments, SocialObjects.Creators.CreatorTagAssignment

    many_to_many :creator_tags, SocialObjects.Creators.CreatorTag,
      join_through: "creator_tag_assignments"

    has_many :purchases, SocialObjects.Creators.CreatorPurchase

    # Fields manually edited via UI (protected from sync overwrites)
    field :manually_edited_fields, {:array, :string}, default: []

    timestamps()
  end

  # Contact fields that can be manually edited
  @contact_fields ~w(email phone first_name last_name address_line_1 address_line_2 city state zipcode country notes is_whitelisted)a

  @doc false
  def changeset(creator, attrs) do
    creator
    |> cast(attrs, [
      :tiktok_username,
      :tiktok_user_id,
      :tiktok_profile_url,
      :previous_tiktok_usernames,
      :tiktok_nickname,
      :tiktok_avatar_url,
      :tiktok_avatar_storage_key,
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
      :outreach_sent_at,
      :sms_consent,
      :sms_consent_at,
      :sms_consent_ip,
      :sms_consent_user_agent,
      :email_opted_out,
      :email_opted_out_at,
      :email_opted_out_reason,
      :cumulative_gmv_cents,
      :cumulative_video_gmv_cents,
      :cumulative_live_gmv_cents,
      :gmv_tracking_started_at,
      :manually_edited_fields
    ])
    |> validate_required([])
    |> normalize_username()
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, message: "must be a valid email")
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

  @doc """
  Returns the list of contact fields that can be manually edited.
  """
  def contact_fields, do: @contact_fields

  @doc """
  Creates a changeset for contact info with optimistic locking.

  Takes a `lock_updated_at` timestamp that must match the creator's current
  `updated_at` to proceed. Returns `{:error, :stale_entry}` if the record
  was modified since the lock was acquired.

  Automatically tracks which fields were changed in `manually_edited_fields`.
  """
  def contact_changeset(creator, attrs, lock_updated_at) do
    # Check for stale entry
    if stale_entry?(creator, lock_updated_at) do
      {:error, :stale_entry}
    else
      changeset = build_contact_changeset(creator, attrs)
      {:ok, changeset}
    end
  end

  defp stale_entry?(%__MODULE__{updated_at: updated_at}, lock_updated_at) do
    # Compare timestamps - if lock_updated_at doesn't match, record was modified
    case {updated_at, lock_updated_at} do
      {nil, _} ->
        false

      {_, nil} ->
        true

      {current, lock} ->
        # Truncate both to seconds for comparison (avoid microsecond differences)
        # updated_at is NaiveDateTime, so use NaiveDateTime.truncate
        NaiveDateTime.truncate(current, :second) != NaiveDateTime.truncate(lock, :second)
    end
  end

  defp build_contact_changeset(creator, attrs) do
    changeset =
      creator
      |> cast(attrs, @contact_fields)
      |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, message: "must be a valid email")

    # Track which fields were changed
    changed_fields = get_changed_contact_fields(changeset)

    if Enum.empty?(changed_fields) do
      changeset
    else
      # Merge new changed fields with existing manually_edited_fields
      existing = creator.manually_edited_fields || []
      new_manually_edited = Enum.uniq(existing ++ changed_fields)
      put_change(changeset, :manually_edited_fields, new_manually_edited)
    end
  end

  defp get_changed_contact_fields(changeset) do
    @contact_fields
    |> Enum.filter(&field_actually_changed?(changeset, &1))
    |> Enum.map(&Atom.to_string/1)
  end

  defp field_actually_changed?(changeset, field) do
    case get_change(changeset, field) do
      nil ->
        false

      new_value ->
        # Only count as changed if the value is actually different
        old_value = Map.get(changeset.data, field)
        normalize_value(new_value) != normalize_value(old_value)
    end
  end

  defp normalize_value(nil), do: nil
  defp normalize_value(""), do: nil
  defp normalize_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_value(value), do: value
end
