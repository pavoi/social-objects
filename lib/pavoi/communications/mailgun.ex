defmodule Pavoi.Communications.Mailgun do
  @moduledoc """
  Mailgun email integration for sending welcome emails to creators.

  Uses the Mailgun REST API to send transactional emails.
  Requires MAILGUN_API_KEY, MAILGUN_DOMAIN, and MAILGUN_FROM_EMAIL
  environment variables.
  """

  require Logger

  alias Pavoi.Communications.Templates
  alias Pavoi.Creators.Creator

  @base_url "https://api.mailgun.net/v3"
  @timeout 30_000

  @doc """
  Sends a welcome email to a creator.

  Returns {:ok, message_id} on success, {:error, reason} on failure.
  """
  def send_welcome_email(creator, lark_invite_url) do
    config = get_config()
    features = get_features()

    if config_valid?(config) do
      do_send_email(creator, lark_invite_url, config, features)
    else
      {:error, "Mailgun not configured - missing API key, domain, or from email"}
    end
  end

  defp do_send_email(creator, lark_invite_url, config, features) do
    original_email = creator.email
    to_email = recipient_email(original_email, features)
    to_name = Creator.full_name(creator) || creator.tiktok_username || "Creator"
    test_mode? = not Map.get(features, :outreach_email_enabled, true)
    override? = to_email != original_email

    form_params =
      %{
        "from" => "#{config.from_name} <#{config.from_email}>",
        "to" => "#{to_name} <#{to_email}>",
        "subject" => Templates.welcome_email_subject(),
        "html" => Templates.welcome_email_html(creator, lark_invite_url),
        "text" => Templates.welcome_email_text(creator, lark_invite_url)
      }
      |> maybe_put_testmode(test_mode?)

    url = "#{@base_url}/#{config.domain}/messages"

    req_opts = [
      url: url,
      auth: {:basic, {"api", config.api_key}},
      finch: Pavoi.Finch,
      form: form_params,
      receive_timeout: @timeout,
      connect_options: [timeout: @timeout]
    ]

    case Req.post(req_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        message_id = parse_message_id(body)

        Logger.info(
          "Mailgun email sent to #{to_email}#{log_override_suffix(override?, original_email)}" <>
            "#{log_testmode_suffix(test_mode?)}, message_id: #{message_id}"
        )

        {:ok, message_id}

      {:ok, %{status: status, body: body}} ->
        error = normalize_body(body)
        Logger.error("Mailgun error (#{status}) for #{to_email}: #{error}")
        {:error, "Mailgun API error: #{status} - #{error}"}

      {:error, exception} ->
        Logger.error(
          "Mailgun request failed for #{to_email}: #{Exception.message(exception)}"
        )

        {:error, "Request failed: #{Exception.message(exception)}"}
    end
  end

  @doc """
  Checks if Mailgun is properly configured.
  """
  def configured? do
    config = get_config()
    config_valid?(config)
  end

  defp get_features do
    Application.get_env(:pavoi, :features, %{})
  end

  defp get_config do
    %{
      api_key: Application.get_env(:pavoi, :mailgun_api_key),
      domain: Application.get_env(:pavoi, :mailgun_domain),
      from_email: Application.get_env(:pavoi, :mailgun_from_email),
      from_name: Application.get_env(:pavoi, :mailgun_from_name, "Pavoi")
    }
  end

  defp config_valid?(config) do
    config.api_key && config.api_key != "" &&
      config.domain && config.domain != "" &&
      config.from_email && config.from_email != ""
  end

  defp recipient_email(original_email, features) do
    override = Map.get(features, :outreach_email_override)

    cond do
      is_binary(override) and String.trim(override) != "" -> String.trim(override)
      true -> original_email
    end
  end

  defp maybe_put_testmode(params, true), do: Map.put(params, "o:testmode", "true")
  defp maybe_put_testmode(params, false), do: params

  defp parse_message_id(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"id" => id}} when is_binary(id) -> id
      _ -> "unknown"
    end
  end

  defp parse_message_id(body), do: normalize_body(body)

  defp normalize_body(body) when is_binary(body), do: body
  defp normalize_body(body), do: inspect(body)

  defp log_override_suffix(true, original_email), do: " (original #{original_email})"
  defp log_override_suffix(false, _original_email), do: ""

  defp log_testmode_suffix(true), do: " [testmode]"
  defp log_testmode_suffix(false), do: ""
end
