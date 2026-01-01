defmodule Pavoi.Outreach do
  @moduledoc """
  The Outreach context handles creator communication automation.

  This context manages the workflow for sending welcome emails and SMS
  to new creators, tracking delivery status, and providing outreach analytics.
  """

  import Ecto.Query, warn: false
  alias Pavoi.Repo

  alias Pavoi.Creators.Creator
  alias Pavoi.Outreach.EmailEvent
  alias Pavoi.Outreach.OutreachLog

  ## Status Management

  @doc """
  Marks a single creator as sent after outreach is delivered.
  Updates outreach_sent_at timestamp.
  """
  def mark_creator_sent(%Creator{} = creator) do
    creator
    |> Creator.changeset(%{
      outreach_sent_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
  end

  ## Email Opt-Out Management

  @doc """
  Marks a creator as opted out of email communications.

  This is called automatically by SendGrid webhooks when:
  - Creator unsubscribes
  - Creator reports spam
  - Email hard bounces

  ## Reasons
    - "unsubscribe" - Creator clicked unsubscribe link
    - "spam_report" - Creator marked email as spam
    - "hard_bounce" - Email permanently undeliverable

  Returns {:ok, creator} or {:error, changeset}.
  """
  def mark_email_opted_out(%Creator{} = creator, reason)
      when reason in ~w(unsubscribe spam_report hard_bounce) do
    # Only update if not already opted out
    if creator.email_opted_out do
      {:ok, creator}
    else
      creator
      |> Creator.changeset(%{
        email_opted_out: true,
        email_opted_out_at: DateTime.utc_now() |> DateTime.truncate(:second),
        email_opted_out_reason: reason
      })
      |> Repo.update()
    end
  end

  @doc """
  Marks a creator as opted out by email address.
  Used by webhooks that only have the email, not the creator struct.

  Returns {:ok, creator}, {:ok, nil} if no creator found, or {:error, changeset}.
  """
  def mark_email_opted_out_by_email(email, reason) when is_binary(email) do
    case find_creator_by_email(email) do
      nil -> {:ok, nil}
      creator -> mark_email_opted_out(creator, reason)
    end
  end

  @doc """
  Finds a creator by email address.
  Returns nil if not found.
  """
  def find_creator_by_email(nil), do: nil

  def find_creator_by_email(email) when is_binary(email) do
    from(c in Creator,
      where: fragment("LOWER(?)", c.email) == ^String.downcase(email),
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Checks if a creator can receive email communications.
  Returns false if the creator has opted out.
  """
  def can_contact_email?(%Creator{email_opted_out: true}), do: false
  def can_contact_email?(%Creator{email: nil}), do: false
  def can_contact_email?(%Creator{email: ""}), do: false
  def can_contact_email?(%Creator{}), do: true

  @doc """
  Generates a signed token for unsubscribe links.
  Token is valid for 90 days.
  """
  def generate_unsubscribe_token(creator_id) do
    Phoenix.Token.sign(PavoiWeb.Endpoint, "unsubscribe", creator_id)
  end

  @doc """
  Verifies an unsubscribe token and returns the creator_id.
  Token must be less than 90 days old.
  """
  def verify_unsubscribe_token(token) do
    # 90 days in seconds
    max_age = 90 * 24 * 60 * 60
    Phoenix.Token.verify(PavoiWeb.Endpoint, "unsubscribe", token, max_age: max_age)
  end

  @doc """
  Generates a signed token for join/consent form links.
  Token encodes both creator_id and lark_preset for redirect after form submission.
  Token is valid for 90 days.
  """
  def generate_join_token(creator_id, lark_preset) do
    Phoenix.Token.sign(PavoiWeb.Endpoint, "join", %{
      creator_id: creator_id,
      lark_preset: lark_preset
    })
  end

  @doc """
  Verifies a join token and returns the payload map with creator_id and lark_preset.
  Token must be less than 90 days old.
  """
  def verify_join_token(token) do
    # 90 days in seconds
    max_age = 90 * 24 * 60 * 60
    Phoenix.Token.verify(PavoiWeb.Endpoint, "join", token, max_age: max_age)
  end

  @doc """
  Updates SMS consent for a creator with full TCPA tracking.
  Records consent timestamp, IP address, and user agent for compliance.
  """
  def update_sms_consent_with_tracking(%Creator{} = creator, phone, ip, user_agent) do
    creator
    |> Creator.changeset(%{
      phone: phone,
      sms_consent: true,
      sms_consent_at: DateTime.utc_now() |> DateTime.truncate(:second),
      sms_consent_ip: ip,
      sms_consent_user_agent: user_agent
    })
    |> Repo.update()
  end

  @doc """
  Updates SMS consent for a creator.
  """
  def update_sms_consent(%Creator{} = creator, consent) when is_boolean(consent) do
    attrs =
      if consent do
        %{
          sms_consent: true,
          sms_consent_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }
      else
        %{sms_consent: false, sms_consent_at: nil}
      end

    creator
    |> Creator.changeset(attrs)
    |> Repo.update()
  end

  ## Outreach Logging

  @doc """
  Logs an outreach attempt for a creator.

  ## Options
    - provider_id: SendGrid message ID or Twilio SID
    - error_message: Error details if failed
    - sent_at: Override send timestamp (defaults to now)
    - lark_preset: Which Lark preset was used (jewelry, active, top_creators)
  """
  def log_outreach(creator_id, channel, status, opts \\ []) do
    %OutreachLog{}
    |> OutreachLog.changeset(%{
      creator_id: creator_id,
      channel: channel,
      status: status,
      provider_id: Keyword.get(opts, :provider_id),
      error_message: Keyword.get(opts, :error_message),
      lark_preset: Keyword.get(opts, :lark_preset),
      sent_at: Keyword.get(opts, :sent_at, DateTime.utc_now() |> DateTime.truncate(:second))
    })
    |> Repo.insert()
  end

  @doc """
  Lists outreach history for a creator, most recent first.
  """
  def list_outreach_history(creator_id) do
    from(ol in OutreachLog,
      where: ol.creator_id == ^creator_id,
      order_by: [desc: ol.sent_at]
    )
    |> Repo.all()
  end

  @doc """
  Gets the most recent email outreach log for a creator.
  Returns nil if no email has been sent.
  """
  def get_latest_email_outreach_log(creator_id) do
    from(ol in OutreachLog,
      where: ol.creator_id == ^creator_id,
      where: ol.channel == "email",
      order_by: [desc: ol.sent_at],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Gets the latest email outreach logs for multiple creators in a single query.
  Returns a map of creator_id => OutreachLog.
  """
  def get_latest_email_outreach_logs(creator_ids) when is_list(creator_ids) do
    # Use a window function to get the latest email log per creator
    from(ol in OutreachLog,
      where: ol.creator_id in ^creator_ids,
      where: ol.channel == "email",
      distinct: ol.creator_id,
      order_by: [ol.creator_id, desc: ol.sent_at]
    )
    |> Repo.all()
    |> Map.new(fn log -> {log.creator_id, log} end)
  end

  ## Statistics

  @doc """
  Gets outreach statistics based on contact status model.

  Returns a map like:
    %{never_contacted: 50, contacted: 100, opted_out: 5, total: 155}
  """
  def get_outreach_stats do
    # Count opted out creators
    opted_out_count =
      from(c in Creator, where: c.email_opted_out == true)
      |> Repo.aggregate(:count)

    # Count creators who have been contacted (have email outreach logs)
    contacted_count =
      from(c in Creator,
        join: ol in OutreachLog,
        on: ol.creator_id == c.id,
        where: ol.channel == "email",
        where: c.email_opted_out == false,
        select: c.id
      )
      |> Repo.all()
      |> Enum.uniq()
      |> length()

    # Total creators
    total_count = Repo.aggregate(Creator, :count)

    # Never contacted = total - contacted - opted_out
    never_contacted = total_count - contacted_count - opted_out_count

    %{
      never_contacted: never_contacted,
      contacted: contacted_count,
      opted_out: opted_out_count,
      total: total_count
    }
  end

  @doc """
  Gets engagement statistics for filtering.

  Returns counts by engagement level:
    %{delivered: 80, opened: 45, clicked: 12, bounced: 3}
  """
  def get_engagement_counts do
    # Get the latest outreach log per creator and count by engagement level
    # This uses a subquery to get the max log ID per creator
    latest_logs_query =
      from(ol in OutreachLog,
        where: ol.channel == "email",
        group_by: ol.creator_id,
        select: %{creator_id: ol.creator_id, max_id: max(ol.id)}
      )

    latest_logs =
      from(ol in OutreachLog,
        join: latest in subquery(latest_logs_query),
        on: ol.id == latest.max_id
      )
      |> Repo.all()

    # Count by engagement level
    counts =
      Enum.reduce(latest_logs, %{delivered: 0, opened: 0, clicked: 0, bounced: 0}, fn log, acc ->
        cond do
          log.clicked_at != nil -> Map.update!(acc, :clicked, &(&1 + 1))
          log.opened_at != nil -> Map.update!(acc, :opened, &(&1 + 1))
          log.bounced_at != nil -> Map.update!(acc, :bounced, &(&1 + 1))
          log.delivered_at != nil -> Map.update!(acc, :delivered, &(&1 + 1))
          true -> acc
        end
      end)

    counts
  end

  @doc """
  Gets the count of messages sent today.
  """
  def count_sent_today do
    today_start =
      Date.utc_today()
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    from(ol in OutreachLog,
      where: ol.sent_at >= ^today_start,
      where: ol.status == "sent"
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Gets total messages sent by channel.

  Returns a map like: %{email: 150, sms: 75}
  """
  def count_total_by_channel do
    from(ol in OutreachLog,
      where: ol.status == "sent",
      group_by: ol.channel,
      select: {ol.channel, count(ol.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Gets a single creator by ID with outreach logs preloaded.
  """
  def get_creator_with_outreach!(id) do
    from(c in Creator,
      where: c.id == ^id,
      preload: [outreach_logs: ^from(ol in OutreachLog, order_by: [desc: ol.sent_at])]
    )
    |> Repo.one!()
  end

  ## Email Events (SendGrid Webhooks)

  @doc """
  Creates an email event from a SendGrid webhook payload.
  """
  def create_email_event(attrs) do
    %EmailEvent{}
    |> EmailEvent.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Finds an outreach log by its SendGrid message ID (provider_id).
  Returns nil if not found.
  """
  def find_outreach_log_by_provider_id(nil), do: nil

  def find_outreach_log_by_provider_id(provider_id) do
    Repo.get_by(OutreachLog, provider_id: provider_id)
  end

  @doc """
  Updates an outreach log's status.
  """
  def update_outreach_log_status(%OutreachLog{} = log, status) do
    log
    |> OutreachLog.changeset(%{status: status})
    |> Repo.update()
  end

  @doc """
  Updates an outreach log's engagement timestamps and/or status.
  Used by the SendGrid webhook to record delivery and engagement events.
  """
  def update_outreach_log_engagement(%OutreachLog{} = log, updates) when is_map(updates) do
    log
    |> OutreachLog.changeset(updates)
    |> Repo.update()
  end

  @doc """
  Lists email events for an outreach log, most recent first.
  """
  def list_email_events_for_log(outreach_log_id) do
    from(e in EmailEvent,
      where: e.outreach_log_id == ^outreach_log_id,
      order_by: [desc: e.timestamp]
    )
    |> Repo.all()
  end

  @doc """
  Gets engagement statistics for outreach emails.

  Returns a map with counts for each event type and calculated rates.
  """
  def get_engagement_stats do
    # Count events by type
    event_counts =
      from(e in EmailEvent,
        group_by: e.event_type,
        select: {e.event_type, count(e.id)}
      )
      |> Repo.all()
      |> Map.new()

    # Count total emails sent (for rate calculation)
    total_sent =
      from(ol in OutreachLog,
        where: ol.channel == "email" and ol.status in ["sent", "delivered"],
        select: count(ol.id)
      )
      |> Repo.one()

    delivered = Map.get(event_counts, "delivered", 0)
    opened = Map.get(event_counts, "open", 0)
    clicked = Map.get(event_counts, "click", 0)

    %{
      total_sent: total_sent,
      delivered: delivered,
      opened: opened,
      clicked: clicked,
      bounced: Map.get(event_counts, "bounce", 0),
      spam_reports: Map.get(event_counts, "spamreport", 0),
      unsubscribes: Map.get(event_counts, "unsubscribe", 0),
      open_rate: if(delivered > 0, do: Float.round(opened / delivered * 100, 1), else: 0.0),
      click_rate: if(delivered > 0, do: Float.round(clicked / delivered * 100, 1), else: 0.0)
    }
  end
end
