defmodule SocialObjects.Accounts.UserNotifier do
  @moduledoc """
  Email notifications for user authentication and invites.
  """

  import Swoosh.Email

  alias SocialObjects.Catalog.Brand
  alias SocialObjects.Mailer
  alias SocialObjects.Settings

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body, opts) do
    brand = Keyword.get(opts, :brand)
    {from_name, from_email} = from_address(brand)
    html = Keyword.get(opts, :html)

    email =
      new()
      |> to(recipient)
      |> from({from_name, from_email})
      |> subject(subject)
      |> text_body(body)

    email = if html, do: html_body(email, html), else: email

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  defp email_template(heading, body_content, button_text, button_url, footer_text, opts) do
    sender_name = Keyword.get(opts, :sender_name, Settings.app_name())

    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
    </head>
    <body style="margin: 0; padding: 0; background-color: #f4f4f5; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;">
      <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background-color: #f4f4f5;">
        <tr>
          <td align="center" style="padding: 40px 20px;">
            <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width: 480px; background-color: #ffffff; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1);">
              <tr>
                <td style="padding: 40px 32px;">
                  <h1 style="margin: 0 0 24px 0; font-size: 22px; font-weight: 600; color: #18181b; line-height: 1.3;">
                    #{heading}
                  </h1>
                  <p style="margin: 0 0 28px 0; font-size: 15px; color: #3f3f46; line-height: 1.6;">
                    #{body_content}
                  </p>
                  <table role="presentation" cellspacing="0" cellpadding="0" style="margin: 0 0 28px 0;">
                    <tr>
                      <td style="background-color: #18181b; border-radius: 6px;">
                        <a href="#{button_url}" target="_blank" style="display: inline-block; padding: 14px 28px; font-size: 15px; font-weight: 500; color: #ffffff; text-decoration: none;">
                          #{button_text}
                        </a>
                      </td>
                    </tr>
                  </table>
                  <p style="margin: 0; font-size: 13px; color: #71717a; line-height: 1.5;">
                    #{footer_text}
                  </p>
                </td>
              </tr>
            </table>
            <p style="margin: 24px 0 0 0; font-size: 12px; color: #a1a1aa;">
              #{sender_name}
            </p>
          </td>
        </tr>
      </table>
    </body>
    </html>
    """
  end

  @doc """
  Deliver a brand invite email.
  """
  def deliver_brand_invite(recipient, %Brand{} = brand, url) do
    brand_name = brand.name || Settings.app_name()

    html =
      email_template(
        "You're invited to #{brand_name}",
        "You've been invited to join #{brand_name}. Click the button below to accept your invitation and get started.",
        "Accept Invitation",
        url,
        "If you weren't expecting this invite, you can safely ignore this email.",
        sender_name: brand_name
      )

    deliver(
      recipient,
      "You're invited to #{brand_name}",
      """
      You've been invited to join #{brand_name}.

      Accept your invitation by visiting this link:

      #{url}

      If you weren't expecting this invite, you can ignore this email.
      """,
      brand: brand,
      html: html
    )
  end

  defp from_address(%Brand{} = brand) do
    {
      Settings.get_sendgrid_from_name(brand.id) || brand.name || Settings.app_name(),
      Settings.get_sendgrid_from_email(brand.id)
    }
  end

  defp from_address(_brand) do
    {
      Settings.auth_from_name(),
      Settings.auth_from_email()
    }
  end
end
