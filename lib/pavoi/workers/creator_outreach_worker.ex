defmodule Pavoi.Workers.CreatorOutreachWorker do
  @moduledoc """
  Oban worker that sends welcome email and SMS to a creator.

  ## Workflow

  1. Receives creator_id and lark_invite_url
  2. Sends welcome email via Swoosh (Local in dev, SendGrid in prod)
  3. If creator has sms_consent=true and valid phone, sends SMS via Twilio
  4. Logs results to outreach_logs
  5. Updates creator.outreach_status to "sent"

  ## Usage

  Called from the /outreach LiveView when user approves outreach:

      Pavoi.Workers.CreatorOutreachWorker.new(%{
        creator_id: 123,
        lark_invite_url: "https://larksuite.com/invite/..."
      })
      |> Oban.insert()

  Or enqueue multiple creators at once:

      Pavoi.Workers.CreatorOutreachWorker.enqueue_batch(creator_ids, lark_invite_url)
  """

  use Oban.Worker,
    queue: :creators,
    max_attempts: 3,
    unique: [period: 300, fields: [:args], keys: [:creator_id]]

  require Logger
  alias Pavoi.Communications.{Email, Twilio}
  alias Pavoi.Creators
  alias Pavoi.Outreach

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"creator_id" => creator_id, "lark_invite_url" => lark_invite_url}
      }) do
    Logger.info("Starting outreach for creator #{creator_id}")

    creator = Creators.get_creator!(creator_id)

    # Verify creator is in approved status
    if creator.outreach_status != "approved" do
      Logger.warning(
        "Creator #{creator_id} not in approved status (#{creator.outreach_status}), skipping"
      )

      {:ok, :skipped}
    else
      send_outreach(creator, lark_invite_url)
    end
  end

  defp send_outreach(creator, lark_invite_url) do
    # Track results
    results = %{email: nil, sms: nil}

    # Send email (required - creator must have email)
    results = send_email(creator, lark_invite_url, results)

    # Send SMS (optional - only if consented and has valid phone)
    results = send_sms(creator, lark_invite_url, results)

    # Mark creator as sent if at least email succeeded
    finalize_outreach(creator, results)
  end

  defp send_email(creator, lark_invite_url, results) do
    if creator.email && creator.email != "" do
      case Email.send_welcome_email(creator, lark_invite_url) do
        {:ok, message_id} ->
          Outreach.log_outreach(creator.id, "email", "sent", provider_id: message_id)
          Map.put(results, :email, {:ok, message_id})

        {:error, reason} ->
          Logger.error("Failed to send email to creator #{creator.id}: #{reason}")
          Outreach.log_outreach(creator.id, "email", "failed", error_message: reason)
          Map.put(results, :email, {:error, reason})
      end
    else
      Logger.warning("Creator #{creator.id} has no email address, skipping email")
      Outreach.log_outreach(creator.id, "email", "failed", error_message: "no_email")
      Map.put(results, :email, {:error, "no_email"})
    end
  end

  defp send_sms(creator, _lark_invite_url, results) when not creator.sms_consent do
    # No consent, skip silently
    Map.put(results, :sms, {:skipped, "no_consent"})
  end

  defp send_sms(creator, lark_invite_url, results) do
    case Twilio.send_welcome_sms(creator, lark_invite_url) do
      {:ok, message_sid} ->
        Outreach.log_outreach(creator.id, "sms", "sent", provider_id: message_sid)
        Map.put(results, :sms, {:ok, message_sid})

      {:error, reason} ->
        log_sms_failure_if_unexpected(creator.id, reason)
        Outreach.log_outreach(creator.id, "sms", "failed", error_message: reason)
        Map.put(results, :sms, {:error, reason})
    end
  end

  defp log_sms_failure_if_unexpected(creator_id, reason) do
    unless reason in ["Creator has not consented to SMS", "Creator has no valid phone number"] do
      Logger.error("Failed to send SMS to creator #{creator_id}: #{reason}")
    end
  end

  defp finalize_outreach(creator, results) do
    case results.email do
      {:ok, _} ->
        # Email succeeded, mark as sent
        {:ok, updated} = Outreach.mark_creator_sent(creator)

        Logger.info(
          "Outreach completed for creator #{creator.id} - email: ok, sms: #{inspect(results.sms)}"
        )

        # Notify any listening LiveViews
        Phoenix.PubSub.broadcast(Pavoi.PubSub, "outreach:updates", {:outreach_sent, updated})

        :ok

      {:error, reason} ->
        # Email failed, don't mark as sent so it can be retried
        Logger.error("Outreach failed for creator #{creator.id} - email failed: #{reason}")
        {:error, "email_failed: #{reason}"}
    end
  end

  @doc """
  Enqueues outreach jobs for multiple creators.

  Returns {:ok, count} with number of jobs enqueued.
  """
  def enqueue_batch(creator_ids, lark_invite_url) when is_list(creator_ids) do
    # First mark all as approved
    Outreach.mark_creators_approved(creator_ids)

    # Then enqueue jobs
    jobs =
      Enum.map(creator_ids, fn creator_id ->
        new(%{creator_id: creator_id, lark_invite_url: lark_invite_url})
      end)

    inserted = Oban.insert_all(jobs)
    {:ok, length(inserted)}
  end

  @doc """
  Enqueues outreach job for a single creator.
  """
  def enqueue(creator_id, lark_invite_url) do
    {:ok, count} = enqueue_batch([creator_id], lark_invite_url)

    if count == 1, do: :ok, else: {:error, "job_not_created"}
  end
end
