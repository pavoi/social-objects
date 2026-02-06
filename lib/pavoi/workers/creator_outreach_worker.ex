defmodule Pavoi.Workers.CreatorOutreachWorker do
  @moduledoc """
  Oban worker that sends email to a creator.

  ## Workflow

  1. Receives creator_id and template_id
  2. Checks if creator can be contacted (not opted out)
  3. Sends email via Swoosh (Local in dev, SendGrid in prod)
  4. Logs result to outreach_logs
  5. Updates creator.outreach_sent_at timestamp

  ## Usage

  Called from the /creators LiveView when user sends outreach:

      Pavoi.Workers.CreatorOutreachWorker.new(%{
        creator_id: 123,
        template_id: 1
      })
      |> Oban.insert()

  Or enqueue multiple creators at once:

      Pavoi.Workers.CreatorOutreachWorker.enqueue_batch(brand_id, creator_ids, template_id)
  """

  use Oban.Worker,
    queue: :creators,
    max_attempts: 3,
    unique: [period: 300, fields: [:args], keys: [:creator_id, :brand_id]]

  require Logger
  alias Pavoi.Communications
  alias Pavoi.Communications.Email
  alias Pavoi.Creators
  alias Pavoi.Outreach

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"creator_id" => creator_id, "template_id" => template_id, "brand_id" => brand_id}
      }) do
    Logger.info("Starting outreach for creator #{creator_id} with template #{template_id}")

    creator = Creators.get_creator!(brand_id, creator_id)
    template = Communications.get_email_template!(brand_id, template_id)

    # Check if creator can be contacted
    if Outreach.can_contact_email?(creator) do
      send_outreach(brand_id, creator, template)
    else
      Logger.warning(
        "Creator #{creator_id} cannot be contacted (opted_out: #{creator.email_opted_out}, reason: #{creator.email_opted_out_reason}), skipping"
      )

      {:ok, :opted_out}
    end
  end

  defp send_outreach(brand_id, creator, template) do
    if creator.email && creator.email != "" do
      case Email.send_templated_email(creator, template) do
        {:ok, message_id} ->
          Outreach.log_outreach(brand_id, creator.id, "email", "sent", provider_id: message_id)
          finalize_outreach(brand_id, creator, {:ok, message_id})

        {:error, reason} ->
          Logger.error("Failed to send email to creator #{creator.id}: #{reason}")
          Outreach.log_outreach(brand_id, creator.id, "email", "failed", error_message: reason)
          {:error, "email_failed: #{reason}"}
      end
    else
      Logger.warning("Creator #{creator.id} has no email address, skipping email")
      Outreach.log_outreach(brand_id, creator.id, "email", "failed", error_message: "no_email")
      {:error, "no_email"}
    end
  end

  defp finalize_outreach(brand_id, creator, {:ok, _message_id}) do
    {:ok, updated} = Outreach.mark_creator_sent(creator)
    Logger.info("Outreach completed for creator #{creator.id}")

    # Notify any listening LiveViews
    Phoenix.PubSub.broadcast(
      Pavoi.PubSub,
      "outreach:updates:#{brand_id}",
      {:outreach_sent, updated}
    )

    :ok
  end

  @doc """
  Enqueues outreach jobs for multiple creators.

  ## Parameters
    - creator_ids: List of creator IDs to send outreach to
    - template_id: ID of the email template to use

  Returns {:ok, count} with number of jobs enqueued.
  """
  def enqueue_batch(brand_id, creator_ids, template_id) when is_list(creator_ids) do
    jobs =
      Enum.map(creator_ids, fn creator_id ->
        new(%{creator_id: creator_id, template_id: template_id, brand_id: brand_id})
      end)

    inserted = Oban.insert_all(jobs)
    {:ok, length(inserted)}
  end

  @doc """
  Enqueues outreach job for a single creator.
  """
  def enqueue(brand_id, creator_id, template_id) do
    {:ok, count} = enqueue_batch(brand_id, [creator_id], template_id)

    if count == 1, do: :ok, else: {:error, "job_not_created"}
  end
end
