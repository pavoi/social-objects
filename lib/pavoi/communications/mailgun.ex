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

    if config_valid?(config) do
      do_send_email(creator, lark_invite_url, config)
    else
      {:error, "Mailgun not configured - missing API key, domain, or from email"}
    end
  end

  defp do_send_email(creator, lark_invite_url, config) do
    to_email = creator.email
    to_name = Creator.full_name(creator) || creator.tiktok_username

    body =
      URI.encode_query(%{
        "from" => "#{config.from_name} <#{config.from_email}>",
        "to" => "#{to_name} <#{to_email}>",
        "subject" => Templates.welcome_email_subject(),
        "html" => Templates.welcome_email_html(creator, lark_invite_url),
        "text" => Templates.welcome_email_text(creator, lark_invite_url)
      })

    url = "#{@base_url}/#{config.domain}/messages"

    headers = [
      {~c"Authorization",
       ~c"Basic " ++ String.to_charlist(Base.encode64("api:#{config.api_key}"))},
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
        message_id = response["id"]
        Logger.info("Mailgun email sent to #{to_email}, message_id: #{message_id}")
        {:ok, message_id}

      {:ok, {{_, status, _}, _headers, response_body}} ->
        error = List.to_string(response_body)
        Logger.error("Mailgun error (#{status}) for #{to_email}: #{error}")
        {:error, "Mailgun API error: #{status} - #{error}"}

      {:error, reason} ->
        Logger.error("Mailgun request failed for #{to_email}: #{inspect(reason)}")
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Checks if Mailgun is properly configured.
  """
  def configured? do
    config = get_config()
    config_valid?(config)
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
end
