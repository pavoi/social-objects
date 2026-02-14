defmodule SocialObjects.Communications.Email do
  @moduledoc """
  Email composition using Swoosh for creator outreach.

  Uses Swoosh.Adapters.Local in development (viewable at /dev/mailbox)
  and Swoosh.Adapters.Sendgrid in production.
  """

  import Swoosh.Email

  alias SocialObjects.Catalog
  alias SocialObjects.Communications.{EmailTemplate, TemplateRenderer}
  alias SocialObjects.Creators.Creator
  alias SocialObjects.Mailer
  alias SocialObjects.Settings

  @spec send_templated_email(Creator.t(), EmailTemplate.t()) ::
          {:ok, binary()} | {:error, binary()}
  @doc """
  Sends an email to a creator using a database-stored template.

  Returns {:ok, message_id} on success, {:error, reason} on failure.
  """
  def send_templated_email(%Creator{} = creator, %EmailTemplate{} = template) do
    brand = Catalog.get_brand!(template.brand_id)
    features = get_features()
    original_email = creator.email
    to_email = recipient_email(original_email, features)
    to_name = Creator.full_name(creator) || creator.tiktok_username || "Creator"

    {rendered_subject, rendered_html, rendered_text} =
      TemplateRenderer.render(template, creator, brand)

    email =
      new()
      |> to({to_name, to_email})
      |> from(from_address(brand))
      |> subject(rendered_subject)
      |> html_body(rendered_html)
      |> text_body(rendered_text)

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
    case Application.get_env(:social_objects, Mailer)[:adapter] do
      Swoosh.Adapters.Local -> true
      Swoosh.Adapters.Sendgrid -> sendgrid_configured?()
      _ -> false
    end
  end

  defp sendgrid_configured? do
    config = Application.get_env(:social_objects, Mailer, [])
    config[:api_key] && config[:api_key] != ""
  end

  defp from_address(brand) do
    from_name = Settings.get_sendgrid_from_name(brand.id) || brand.name || Settings.app_name()
    from_email = Settings.get_sendgrid_from_email(brand.id)

    {from_name, from_email}
  end

  defp get_features do
    Application.get_env(:social_objects, :features, [])
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
