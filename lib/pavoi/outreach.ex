defmodule Pavoi.Outreach do
  @moduledoc """
  The Outreach context handles creator communication automation.

  This context manages the workflow for sending welcome emails and SMS
  to new creators, tracking delivery status, and providing outreach analytics.
  """

  import Ecto.Query, warn: false
  alias Pavoi.Repo

  alias Pavoi.Creators.Creator
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
  """
  def list_creators_by_status(status, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)
    search_query = Keyword.get(opts, :search_query, "")

    base_query =
      from(c in Creator, where: c.outreach_status == ^status)
      |> apply_search_filter(search_query)

    total = Repo.aggregate(base_query, :count)

    creators =
      base_query
      |> order_by([c], desc: c.inserted_at)
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
  """
  def log_outreach(creator_id, channel, status, opts \\ []) do
    %OutreachLog{}
    |> OutreachLog.changeset(%{
      creator_id: creator_id,
      channel: channel,
      status: status,
      provider_id: Keyword.get(opts, :provider_id),
      error_message: Keyword.get(opts, :error_message),
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
end
