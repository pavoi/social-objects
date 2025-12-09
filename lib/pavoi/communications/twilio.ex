defmodule Pavoi.Communications.Twilio do
  @moduledoc """
  Twilio SMS integration for sending welcome messages to creators.

  Uses the Twilio REST API to send SMS messages.
  Requires TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, and TWILIO_FROM_NUMBER
  environment variables.
  """

  require Logger

  @base_url "https://api.twilio.com/2010-04-01"
  @timeout 30_000

  @doc """
  Sends a welcome SMS to a creator.

  Returns {:ok, message_sid} on success, {:error, reason} on failure.

  Note: Only sends if creator has sms_consent = true and has a valid phone number.
  """
  def send_welcome_sms(creator, lark_invite_url) do
    config = get_config()

    cond do
      !config_valid?(config) ->
        {:error, "Twilio not configured - missing account SID, auth token, or from number"}

      !creator.sms_consent ->
        {:error, "Creator has not consented to SMS"}

      !valid_phone?(creator.phone) ->
        {:error, "Creator has no valid phone number"}

      true ->
        do_send_sms(creator, lark_invite_url, config)
    end
  end

  defp do_send_sms(creator, lark_invite_url, config) do
    alias Pavoi.Communications.Templates

    to_phone = normalize_to_e164(creator.phone)
    message_body = Templates.welcome_sms_body(creator, lark_invite_url)

    body =
      URI.encode_query(%{
        "To" => to_phone,
        "From" => config.from_number,
        "Body" => message_body
      })

    url = "#{@base_url}/Accounts/#{config.account_sid}/Messages.json"

    headers = [
      {~c"Authorization",
       ~c"Basic " ++
         String.to_charlist(Base.encode64("#{config.account_sid}:#{config.auth_token}"))},
      {~c"Content-Type", ~c"application/x-www-form-urlencoded"}
    ]

    case :httpc.request(
           :post,
           {String.to_charlist(url), headers, ~c"application/x-www-form-urlencoded",
            String.to_charlist(body)},
           [{:timeout, @timeout}, {:connect_timeout, @timeout}],
           []
         ) do
      {:ok, {{_, status, _}, _headers, response_body}} when status in 200..299 ->
        response = Jason.decode!(List.to_string(response_body))
        message_sid = response["sid"]
        Logger.info("Twilio SMS sent to #{to_phone}, sid: #{message_sid}")
        {:ok, message_sid}

      {:ok, {{_, status, _}, _headers, response_body}} ->
        error = List.to_string(response_body)
        Logger.error("Twilio error (#{status}) for #{to_phone}: #{error}")
        {:error, "Twilio API error: #{status} - #{error}"}

      {:error, reason} ->
        Logger.error("Twilio request failed for #{to_phone}: #{inspect(reason)}")
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Checks if Twilio is properly configured.
  """
  def configured? do
    config = get_config()
    config_valid?(config)
  end

  defp get_config do
    %{
      account_sid: Application.get_env(:pavoi, :twilio_account_sid),
      auth_token: Application.get_env(:pavoi, :twilio_auth_token),
      from_number: Application.get_env(:pavoi, :twilio_from_number)
    }
  end

  defp config_valid?(config) do
    config.account_sid && config.account_sid != "" &&
      config.auth_token && config.auth_token != "" &&
      config.from_number && config.from_number != ""
  end

  defp valid_phone?(nil), do: false
  defp valid_phone?(""), do: false

  defp valid_phone?(phone) do
    # Check that we have at least 10 digits and no masked characters
    digits = String.replace(phone, ~r/[^\d]/, "")
    String.length(digits) >= 10 && !String.contains?(phone, "*")
  end

  defp normalize_to_e164(phone) do
    digits = String.replace(phone, ~r/[^\d]/, "")

    cond do
      # Already has country code (11+ digits starting with 1 for US)
      String.length(digits) >= 11 && String.starts_with?(digits, "1") ->
        "+#{digits}"

      # 10 digit US number, add +1
      String.length(digits) == 10 ->
        "+1#{digits}"

      # Already in E.164 format with +
      String.starts_with?(phone, "+") ->
        phone

      # Fallback: assume US and add +1
      true ->
        "+1#{digits}"
    end
  end
end
