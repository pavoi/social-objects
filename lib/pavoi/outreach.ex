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

  ## Pending Creators

  @doc """
  Lists creators with pending outreach status, paginated.

  ## Options
    - page: Current page number (default: 1)
    - per_page: Items per page (default: 50)
    - search_query: Search by username, email, first/last name

  ## Returns
    A map with creators, total, page, per_page, has_more
  """
  def list_pending_creators(opts \\ []) do
    list_creators_by_status("pending", opts)
  end

  @doc """
  Lists creators by outreach status, paginated.

  ## Options
    - page: Current page number (default: 1)
    - per_page: Items per page (default: 50)
    - search_query: Search by username, email, first/last name
    - sort_by: Column to sort by (username, name, email, phone, sms_consent, added, sent)
    - sort_dir: Sort direction (asc, desc)
  """
  def list_creators_by_status(status, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)
    search_query = Keyword.get(opts, :search_query, "")
    sort_by = Keyword.get(opts, :sort_by)
    sort_dir = Keyword.get(opts, :sort_dir, "desc")

    base_query =
      from(c in Creator, where: c.outreach_status == ^status)
      |> apply_search_filter(search_query)

    total = Repo.aggregate(base_query, :count)

    creators =
      base_query
      |> apply_outreach_sort(sort_by, sort_dir)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    %{
      creators: creators,
      total: total,
      page: page,
      per_page: per_page,
      has_more: total > page * per_page
    }
  end

  defp apply_outreach_sort(query, "username", "asc"),
    do: order_by(query, [c], asc_nulls_last: c.tiktok_username)

  defp apply_outreach_sort(query, "username", "desc"),
    do: order_by(query, [c], desc_nulls_last: c.tiktok_username)

  defp apply_outreach_sort(query, "name", "asc"),
    do: order_by(query, [c], asc_nulls_last: c.first_name, asc_nulls_last: c.last_name)

  defp apply_outreach_sort(query, "name", "desc"),
    do: order_by(query, [c], desc_nulls_last: c.first_name, desc_nulls_last: c.last_name)

  defp apply_outreach_sort(query, "email", "asc"),
    do: order_by(query, [c], asc_nulls_last: c.email)

  defp apply_outreach_sort(query, "email", "desc"),
    do: order_by(query, [c], desc_nulls_last: c.email)

  defp apply_outreach_sort(query, "phone", "asc"),
    do: order_by(query, [c], asc_nulls_last: c.phone)

  defp apply_outreach_sort(query, "phone", "desc"),
    do: order_by(query, [c], desc_nulls_last: c.phone)

  defp apply_outreach_sort(query, "sms_consent", "asc"),
    do: order_by(query, [c], asc_nulls_last: c.sms_consent)

  defp apply_outreach_sort(query, "sms_consent", "desc"),
    do: order_by(query, [c], desc_nulls_last: c.sms_consent)

  defp apply_outreach_sort(query, "added", "asc"),
    do: order_by(query, [c], asc: c.inserted_at)

  defp apply_outreach_sort(query, "added", "desc"),
    do: order_by(query, [c], desc: c.inserted_at)

  defp apply_outreach_sort(query, "sent", "asc"),
    do: order_by(query, [c], asc_nulls_last: c.outreach_sent_at)

  defp apply_outreach_sort(query, "sent", "desc"),
    do: order_by(query, [c], desc_nulls_last: c.outreach_sent_at)

  # Default: sort by inserted_at descending (most recent first)
  defp apply_outreach_sort(query, _, _),
    do: order_by(query, [c], desc: c.inserted_at)

  defp apply_search_filter(query, ""), do: query

  defp apply_search_filter(query, search_query) do
    pattern = "%#{search_query}%"

    where(
      query,
      [c],
      ilike(c.tiktok_username, ^pattern) or
        ilike(c.email, ^pattern) or
        ilike(c.first_name, ^pattern) or
        ilike(c.last_name, ^pattern)
    )
  end

  ## Status Management

  @doc """
  Marks creators as approved for outreach.
  Returns the count of updated records.
  """
  def mark_creators_approved(creator_ids) when is_list(creator_ids) do
    from(c in Creator,
      where: c.id in ^creator_ids,
      where: c.outreach_status == "pending"
    )
    |> Repo.update_all(set: [outreach_status: "approved"])
    |> elem(0)
  end

  @doc """
  Marks creators as skipped (will not receive outreach).
  Returns the count of updated records.
  """
  def mark_creators_skipped(creator_ids) when is_list(creator_ids) do
    from(c in Creator,
      where: c.id in ^creator_ids,
      where: c.outreach_status in ["pending", "approved"]
    )
    |> Repo.update_all(set: [outreach_status: "skipped"])
    |> elem(0)
  end

  @doc """
  Marks a single creator as sent after outreach is delivered.
  """
  def mark_creator_sent(%Creator{} = creator) do
    creator
    |> Creator.changeset(%{
      outreach_status: "sent",
      outreach_sent_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
  end

  @doc """
  Marks a creator as unsubscribed from outreach emails.
  """
  def mark_creator_unsubscribed(%Creator{} = creator) do
    creator
    |> Creator.changeset(%{outreach_status: "unsubscribed"})
    |> Repo.update()
  end

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
  Gets outreach statistics (counts by status).

  Returns a map like:
    %{pending: 10, approved: 5, sent: 100, skipped: 3, total: 118}
  """
  def get_outreach_stats do
    # Count by status
    status_counts =
      from(c in Creator,
        where: not is_nil(c.outreach_status),
        group_by: c.outreach_status,
        select: {c.outreach_status, count(c.id)}
      )
      |> Repo.all()
      |> Map.new()

    # Also count creators with no outreach status (existing before automation)
    no_status_count =
      from(c in Creator, where: is_nil(c.outreach_status))
      |> Repo.aggregate(:count)

    %{
      pending: Map.get(status_counts, "pending", 0),
      approved: Map.get(status_counts, "approved", 0),
      sent: Map.get(status_counts, "sent", 0),
      skipped: Map.get(status_counts, "skipped", 0),
      no_status: no_status_count,
      total: Enum.sum(Map.values(status_counts)) + no_status_count
    }
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

  ## Bulk Operations

  @doc """
  Gets all approved creators that haven't been sent yet.
  Used by the outreach worker.
  """
  def list_approved_creators do
    from(c in Creator,
      where: c.outreach_status == "approved",
      order_by: [asc: c.inserted_at]
    )
    |> Repo.all()
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
