defmodule Pavoi.Outreach.OutreachLog do
  @moduledoc """
  Logs outreach communications sent to creators.

  Tracks email and SMS messages sent via SendGrid and Twilio,
  including delivery status and any errors.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @channels ~w(email sms)
  @statuses ~w(sent failed bounced delivered)

  schema "outreach_logs" do
    belongs_to :creator, Pavoi.Creators.Creator

    # Channel: "email" or "sms"
    field :channel, :string

    # Status: "sent", "failed", "bounced", "delivered"
    field :status, :string

    # Provider message ID (SendGrid message ID or Twilio SID)
    field :provider_id, :string

    # Error details if failed
    field :error_message, :string

    # When the message was sent
    field :sent_at, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(outreach_log, attrs) do
    outreach_log
    |> cast(attrs, [
      :creator_id,
      :channel,
      :status,
      :provider_id,
      :error_message,
      :sent_at
    ])
    |> validate_required([:creator_id, :channel, :status, :sent_at])
    |> validate_inclusion(:channel, @channels)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:creator_id)
  end

  @doc """
  Returns the list of valid channels.
  """
  def channels, do: @channels

  @doc """
  Returns the list of valid statuses.
  """
  def statuses, do: @statuses
end
