defmodule PavoiWeb.Plugs.SendgridSignature do
  @moduledoc """
  Verifies SendGrid Event Webhook signatures using ECDSA.

  SendGrid signs webhook requests with ECDSA using a public/private key pair.
  The signature is sent in the `X-Twilio-Email-Event-Webhook-Signature` header.
  The timestamp is sent in the `X-Twilio-Email-Event-Webhook-Timestamp` header.

  To verify:
  1. Get the signature and timestamp from headers
  2. Concatenate: timestamp + payload (raw bytes)
  3. Verify ECDSA signature against the concatenated value

  ## Configuration

  Set the verification key in your environment:

      SENDGRID_WEBHOOK_VERIFICATION_KEY="MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE..."

  The key should be the Base64-encoded public key from SendGrid's
  Event Webhook settings page (when Signed Event Webhook is enabled).
  """

  require Logger

  alias PavoiWeb.Plugs.CacheRawBody

  @signature_header "x-twilio-email-event-webhook-signature"
  @timestamp_header "x-twilio-email-event-webhook-timestamp"

  @doc """
  Verifies the SendGrid webhook signature.

  Returns :ok if valid, {:error, reason} if invalid or verification is not configured.
  """
  def verify(conn) do
    case get_verification_key() do
      nil ->
        # If no key configured, skip verification (allows gradual rollout)
        Logger.debug("[SendGrid Webhook] Signature verification not configured, skipping")
        :ok

      public_key ->
        do_verify(conn, public_key)
    end
  end

  @doc """
  Checks if signature verification is enabled.
  """
  def enabled? do
    get_verification_key() != nil
  end

  defp do_verify(conn, public_key) do
    with {:ok, signature} <- get_header(conn, @signature_header),
         {:ok, timestamp} <- get_header(conn, @timestamp_header),
         {:ok, raw_body} <- get_raw_body(conn),
         {:ok, decoded_sig} <- decode_signature(signature),
         :ok <- verify_signature(public_key, timestamp, raw_body, decoded_sig) do
      :ok
    else
      {:error, reason} = error ->
        Logger.warning("[SendGrid Webhook] Signature verification failed: #{reason}")
        error
    end
  end

  defp get_header(conn, header_name) do
    case Plug.Conn.get_req_header(conn, header_name) do
      [value | _] -> {:ok, value}
      [] -> {:error, "missing #{header_name} header"}
    end
  end

  defp get_raw_body(conn) do
    case CacheRawBody.get_raw_body(conn) do
      nil -> {:error, "raw body not cached"}
      body -> {:ok, body}
    end
  end

  defp decode_signature(signature) do
    case Base.decode64(signature) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, "invalid base64 signature"}
    end
  end

  defp verify_signature(public_key_pem, timestamp, payload, signature) do
    # The payload to verify is: timestamp + raw_body
    message = timestamp <> payload

    # Parse the PEM-encoded public key
    case decode_public_key(public_key_pem) do
      {:ok, public_key} ->
        # Verify the ECDSA signature
        if :crypto.verify(:ecdsa, :sha256, message, signature, [public_key, :prime256v1]) do
          :ok
        else
          {:error, "signature mismatch"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("[SendGrid Webhook] Signature verification error: #{inspect(e)}")
      {:error, "verification error"}
  end

  defp decode_public_key(pem_string) do
    # Try parsing as PEM first
    case :public_key.pem_decode(pem_string) do
      [{:SubjectPublicKeyInfo, der, _}] ->
        public_key = :public_key.der_decode(:SubjectPublicKeyInfo, der)
        {:ok, extract_ec_point(public_key)}

      [] ->
        # If not PEM, try as raw base64 DER
        case Base.decode64(pem_string) do
          {:ok, der} ->
            public_key = :public_key.der_decode(:SubjectPublicKeyInfo, der)
            {:ok, extract_ec_point(public_key)}

          :error ->
            {:error, "invalid public key format"}
        end

      _ ->
        {:error, "unexpected PEM format"}
    end
  rescue
    e ->
      Logger.error("[SendGrid Webhook] Failed to parse public key: #{inspect(e)}")
      {:error, "failed to parse public key"}
  end

  defp extract_ec_point({:SubjectPublicKeyInfo, _algorithm, public_key_bits}) do
    public_key_bits
  end

  defp get_verification_key do
    Application.get_env(:pavoi, :sendgrid_webhook_verification_key)
  end
end
