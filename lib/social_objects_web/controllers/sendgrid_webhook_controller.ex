defmodule SocialObjectsWeb.SendgridWebhookController do
  @moduledoc """
  Handles SendGrid Event Webhook callbacks.

  SendGrid sends batched event notifications as POST requests containing
  an array of event objects. Each event includes information about email
  delivery status and engagement (opens, clicks, etc.).

  Configure the webhook URL in SendGrid: Settings > Mail Settings > Event Notification
  URL: https://your-domain.com/webhooks/sendgrid

  ## Signature Verification

  When `SENDGRID_WEBHOOK_VERIFICATION_KEY` is set, incoming requests are
  verified using SendGrid's ECDSA signature. Invalid signatures return 403.
  """
  use SocialObjectsWeb, :controller

  alias SocialObjects.Outreach
  alias SocialObjectsWeb.Plugs.SendgridSignature

  require Logger

  @doc """
  Handles incoming webhook events from SendGrid.

  SendGrid sends an array of events in the request body.
  We process each event and always return 200 to acknowledge receipt.
  Returns 403 if signature verification fails.
  """
  def handle(conn, _params) do
    case SendgridSignature.verify(conn) do
      :ok ->
        process_webhook(conn)

      {:error, reason} ->
        Logger.warning("[SendGrid Webhook] Rejected: #{reason}")
        send_resp(conn, 403, "Forbidden")
    end
  end

  defp process_webhook(conn) do
    # Phoenix wraps JSON arrays in "_json" key
    events =
      case conn.body_params do
        %{"_json" => list} when is_list(list) -> list
        list when is_list(list) -> list
        other -> other
      end

    case events do
      events when is_list(events) ->
        Enum.each(events, &process_event/1)

      _ ->
        Logger.warning("[SendGrid Webhook] Unexpected payload format: #{inspect(events)}")
    end

    # Always return 200 to SendGrid to acknowledge receipt
    send_resp(conn, 200, "ok")
  end

  defp process_event(event) when is_map(event) do
    event_type = Map.get(event, "event")
    sg_message_id = extract_message_id(event)
    timestamp = parse_timestamp(Map.get(event, "timestamp"))
    email = Map.get(event, "email")

    # Find the matching outreach log by SendGrid message ID
    outreach_log = Outreach.find_outreach_log_by_provider_id(sg_message_id)

    # Create the email event record
    attrs = %{
      outreach_log_id: if(outreach_log, do: outreach_log.id),
      event_type: event_type,
      email: email,
      timestamp: timestamp,
      url: Map.get(event, "url"),
      reason: extract_reason(event),
      sg_message_id: sg_message_id,
      raw_payload: event
    }

    case Outreach.create_email_event(attrs) do
      {:ok, _event} ->
        # Update outreach log engagement timestamps and status
        _ = update_outreach_log_engagement(outreach_log, event_type, timestamp)

        # Auto opt-out creators on negative events
        _ = maybe_opt_out_creator(event_type, email, event)

      {:error, changeset} ->
        Logger.warning("[SendGrid Webhook] Failed to create event: #{inspect(changeset.errors)}")
    end
  end

  defp process_event(event) do
    Logger.warning("[SendGrid Webhook] Invalid event format: #{inspect(event)}")
  end

  # SendGrid message ID appears in sg_message_id field
  # Format varies: "abc123" or "abc123.recvd-xxx" or "abc123.filter-xxx" or "abc123@sendgrid.net"
  # We store just the base ID (before any dot or @), so extract that for matching
  defp extract_message_id(event) do
    case Map.get(event, "sg_message_id") do
      nil -> nil
      id -> id |> String.split(~r/[.@]/, parts: 2) |> List.first()
    end
  end

  defp parse_timestamp(nil), do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp parse_timestamp(unix_timestamp) when is_integer(unix_timestamp) do
    DateTime.from_unix!(unix_timestamp) |> DateTime.truncate(:second)
  end

  defp parse_timestamp(unix_timestamp) when is_binary(unix_timestamp) do
    case Integer.parse(unix_timestamp) do
      {ts, _} -> DateTime.from_unix!(ts) |> DateTime.truncate(:second)
      :error -> DateTime.utc_now() |> DateTime.truncate(:second)
    end
  end

  defp extract_reason(event) do
    # Bounce and drop events include reason information
    cond do
      Map.has_key?(event, "reason") -> Map.get(event, "reason")
      Map.has_key?(event, "bounce_classification") -> Map.get(event, "bounce_classification")
      true -> nil
    end
  end

  # Update engagement timestamps on the outreach log
  # Only sets the timestamp if not already set (first occurrence wins)
  defp update_outreach_log_engagement(nil, _event_type, _timestamp), do: :ok

  defp update_outreach_log_engagement(outreach_log, event_type, timestamp) do
    updates = engagement_updates(event_type, timestamp, outreach_log)

    if map_size(updates) > 0 do
      Outreach.update_outreach_log_engagement(outreach_log, updates)
    else
      :ok
    end
  end

  defp engagement_updates("delivered", timestamp, %{delivered_at: nil}) do
    %{delivered_at: timestamp, status: :delivered}
  end

  defp engagement_updates("delivered", _timestamp, _log), do: %{status: :delivered}

  defp engagement_updates("open", timestamp, %{opened_at: nil}), do: %{opened_at: timestamp}
  defp engagement_updates("open", _timestamp, _log), do: %{}

  defp engagement_updates("click", timestamp, %{clicked_at: nil}), do: %{clicked_at: timestamp}
  defp engagement_updates("click", _timestamp, _log), do: %{}

  defp engagement_updates("bounce", timestamp, %{bounced_at: nil}) do
    %{bounced_at: timestamp, status: :bounced}
  end

  defp engagement_updates("bounce", _timestamp, _log), do: %{status: :bounced}

  defp engagement_updates("dropped", _timestamp, _log), do: %{status: :failed}

  defp engagement_updates("spamreport", timestamp, %{spam_reported_at: nil}) do
    %{spam_reported_at: timestamp}
  end

  defp engagement_updates("spamreport", _timestamp, _log), do: %{}

  defp engagement_updates("unsubscribe", timestamp, %{unsubscribed_at: nil}) do
    %{unsubscribed_at: timestamp}
  end

  defp engagement_updates("unsubscribe", _timestamp, _log), do: %{}

  defp engagement_updates("group_unsubscribe", timestamp, %{unsubscribed_at: nil}) do
    %{unsubscribed_at: timestamp}
  end

  defp engagement_updates("group_unsubscribe", _timestamp, _log), do: %{}

  defp engagement_updates(_event_type, _timestamp, _log), do: %{}

  # Auto opt-out creators on unsubscribe, spam report, or hard bounce
  defp maybe_opt_out_creator("unsubscribe", email, _event) do
    case Outreach.mark_email_opted_out_by_email(email, "unsubscribe") do
      {:ok, nil} ->
        :ok

      {:ok, creator} ->
        Logger.info("[SendGrid Webhook] Opted out creator #{creator.id} (unsubscribe)")

      {:error, _} ->
        :ok
    end
  end

  defp maybe_opt_out_creator("group_unsubscribe", email, _event) do
    case Outreach.mark_email_opted_out_by_email(email, "unsubscribe") do
      {:ok, nil} ->
        :ok

      {:ok, creator} ->
        Logger.info("[SendGrid Webhook] Opted out creator #{creator.id} (group unsubscribe)")

      {:error, _} ->
        :ok
    end
  end

  defp maybe_opt_out_creator("spamreport", email, _event) do
    case Outreach.mark_email_opted_out_by_email(email, "spam_report") do
      {:ok, nil} ->
        :ok

      {:ok, creator} ->
        Logger.info("[SendGrid Webhook] Opted out creator #{creator.id} (spam report)")

      {:error, _} ->
        :ok
    end
  end

  defp maybe_opt_out_creator("bounce", email, event) do
    # Only opt-out on hard bounces (permanent delivery failures)
    # SendGrid bounce types: 1=soft, 2=unknown, 5=hard
    # Also check bounce_classification for "Invalid Addresses" which indicates hard bounce
    is_hard_bounce =
      Map.get(event, "type") == "5" or
        Map.get(event, "bounce_classification") == "Invalid Addresses"

    if is_hard_bounce do
      case Outreach.mark_email_opted_out_by_email(email, "hard_bounce") do
        {:ok, nil} ->
          :ok

        {:ok, creator} ->
          Logger.info("[SendGrid Webhook] Opted out creator #{creator.id} (hard bounce)")

        {:error, _} ->
          :ok
      end
    else
      :ok
    end
  end

  defp maybe_opt_out_creator(_event_type, _email, _event), do: :ok
end
