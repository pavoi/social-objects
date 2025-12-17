defmodule Pavoi.Communications.Email do
  @moduledoc """
  Email composition using Swoosh for creator outreach.

  Uses Swoosh.Adapters.Local in development (viewable at /dev/mailbox)
  and Swoosh.Adapters.Sendgrid in production.
  """

  import Swoosh.Email

  alias Pavoi.Communications.Templates
  alias Pavoi.Creators.Creator
  alias Pavoi.Mailer

  @doc """
  Sends a welcome email to a creator.

  Returns {:ok, %Swoosh.Email{}} on success, {:error, reason} on failure.
  """
  def send_welcome_email(creator, lark_invite_url) do
    features = get_features()
    original_email = creator.email
    to_email = recipient_email(original_email, features)
    to_name = Creator.full_name(creator) || creator.tiktok_username || "Creator"

    email =
      new()
      |> to({to_name, to_email})
      |> from(from_address())
      |> subject(Templates.welcome_email_subject())
      |> html_body(Templates.welcome_email_html(creator, lark_invite_url))
      |> text_body(Templates.welcome_email_text(creator, lark_invite_url))

    case Mailer.deliver(email) do
      {:ok, metadata} ->
        message_id = extract_message_id(metadata)
        {:ok, message_id}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  @doc """
  Checks if the mailer is properly configured for production use.

  In development with Local adapter, always returns true.
  In production with SendGrid adapter, checks for required env vars.
  """
  def configured? do
    case Application.get_env(:pavoi, Mailer)[:adapter] do
      Swoosh.Adapters.Local -> true
      Swoosh.Adapters.Sendgrid -> sendgrid_configured?()
      _ -> false
    end
  end

  defp sendgrid_configured? do
    config = Application.get_env(:pavoi, Mailer, [])
    config[:api_key] && config[:api_key] != ""
  end

  defp from_address do
    from_name = non_empty_string(Application.get_env(:pavoi, :sendgrid_from_name), "Pavoi")

    from_email =
      non_empty_string(Application.get_env(:pavoi, :sendgrid_from_email), "noreply@pavoi.com")

    {from_name, from_email}
  end

  defp non_empty_string(value, _default) when is_binary(value) and value != "", do: value
  defp non_empty_string(_, default), do: default

  defp get_features do
    Application.get_env(:pavoi, :features, [])
  end

  defp recipient_email(original_email, features) do
    override = Keyword.get(features, :outreach_email_override)

    if is_binary(override) and String.trim(override) != "" do
      String.trim(override)
    else
      original_email
    end
  end

  defp extract_message_id(%{id: id}) when is_binary(id), do: id
  defp extract_message_id(metadata) when is_map(metadata), do: inspect(metadata)
  defp extract_message_id(_), do: "local"

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
