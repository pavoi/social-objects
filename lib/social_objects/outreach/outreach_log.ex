defmodule SocialObjects.Outreach.OutreachLog do
  @moduledoc """
  Logs outreach communications sent to creators.

  Tracks email and SMS messages sent via SendGrid and Twilio,
  including delivery status and any errors.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type channel :: :email | :sms
  @type status :: :sent | :failed | :bounced | :delivered

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          brand_id: pos_integer() | nil,
          creator_id: pos_integer() | nil,
          channel: channel(),
          lark_preset: String.t() | nil,
          status: status(),
          provider_id: String.t() | nil,
          error_message: String.t() | nil,
          sent_at: DateTime.t() | nil,
          delivered_at: DateTime.t() | nil,
          opened_at: DateTime.t() | nil,
          clicked_at: DateTime.t() | nil,
          bounced_at: DateTime.t() | nil,
          spam_reported_at: DateTime.t() | nil,
          unsubscribed_at: DateTime.t() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  @channels ~w(email sms)a
  @statuses ~w(sent failed bounced delivered)a

  alias SocialObjects.Outreach.EmailEvent

  schema "outreach_logs" do
    belongs_to :brand, SocialObjects.Catalog.Brand
    belongs_to :creator, SocialObjects.Creators.Creator
    has_many :email_events, EmailEvent

    # Channel: :email or :sms
    field :channel, Ecto.Enum, values: @channels

    # Lark preset used for this outreach (jewelry, active, top_creators)
    field :lark_preset, :string

    # Status: :sent, :failed, :bounced, :delivered
    field :status, Ecto.Enum, values: @statuses

    # Provider message ID (SendGrid message ID or Twilio SID)
    field :provider_id, :string

    # Error details if failed
    field :error_message, :string

    # When the message was sent
    field :sent_at, :utc_datetime

    # Engagement timestamps (set by webhook events)
    field :delivered_at, :utc_datetime
    field :opened_at, :utc_datetime
    field :clicked_at, :utc_datetime
    field :bounced_at, :utc_datetime
    field :spam_reported_at, :utc_datetime
    field :unsubscribed_at, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(outreach_log, attrs) do
    outreach_log
    |> cast(attrs, [
      :creator_id,
      :channel,
      :lark_preset,
      :status,
      :provider_id,
      :error_message,
      :sent_at,
      :delivered_at,
      :opened_at,
      :clicked_at,
      :bounced_at,
      :spam_reported_at,
      :unsubscribed_at
    ])
    |> validate_required([:brand_id, :creator_id, :channel, :status, :sent_at])
    |> foreign_key_constraint(:creator_id)
    |> foreign_key_constraint(:brand_id)
  end

  @doc """
  Returns the list of valid channels.
  """
  def channels, do: @channels

  @doc """
  Returns the list of valid statuses.
  """
  def statuses, do: @statuses

  @doc """
  Computes the engagement status for display purposes.

  Returns a tuple of {status_label, status_type} where status_type is used for styling:
  - :pending - not yet sent
  - :sent - sent but no delivery confirmation
  - :delivered - delivered to inbox
  - :opened - recipient opened email
  - :clicked - recipient clicked a link
  - :bounced - email bounced (negative)
  - :spam - marked as spam (negative)
  - :unsubscribed - recipient unsubscribed (neutral/negative)
  - :skipped - manually skipped

  Negative outcomes take precedence. For positive outcomes, shows highest engagement.
  """
  def engagement_status(nil), do: {"Pending", :pending}

  def engagement_status(%__MODULE__{} = log) do
    negative_outcome(log) || positive_outcome(log) || status_outcome(log)
  end

  defp negative_outcome(log) do
    cond do
      log.bounced_at -> {"Bounced", :bounced}
      log.spam_reported_at -> {"Spam", :spam}
      log.unsubscribed_at -> {"Unsubscribed", :unsubscribed}
      true -> nil
    end
  end

  defp positive_outcome(log) do
    cond do
      log.clicked_at -> {"Clicked", :clicked}
      log.opened_at -> {"Opened", :opened}
      log.delivered_at -> {"Delivered", :delivered}
      true -> nil
    end
  end

  defp status_outcome(log) do
    case log.status do
      :sent -> {"Sent", :sent}
      :delivered -> {"Delivered", :delivered}
      :bounced -> {"Bounced", :bounced}
      :failed -> {"Failed", :bounced}
      _ -> {"Sent", :sent}
    end
  end
end
