defmodule Pavoi.Communications.Templates do
  @moduledoc """
  Email and SMS templates for creator outreach.

  Templates are customizable via system settings or can be edited
  directly in this module for more control.
  """

  alias Pavoi.Creators.Creator

  @doc """
  Returns the welcome email subject line.
  """
  def welcome_email_subject do
    "You're invited to the Pavoi Creator Program"
  end

  @doc """
  Returns the welcome email HTML body.

  The join_url parameter is the URL to the consent/join form page,
  which captures phone number and SMS consent before redirecting to Lark.
  """
  @brand_dark_green "#2E4042"
  @brand_sage "#A9BDB6"
  @brand_font "Georgia, 'Times New Roman', serif"

  def welcome_email_html(creator, join_url) do
    name = get_display_name(creator)
    unsubscribe_url = unsubscribe_url(creator)

    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Welcome to Pavoi</title>
    </head>
    <body style="font-family: #{@brand_font}; line-height: 1.7; color: #{@brand_dark_green}; max-width: 600px; margin: 0 auto; padding: 0; background-color: #f8f8f8;">
      <div style="background: #ffffff; margin: 20px;">
        <!-- Header -->
        <div style="text-align: center; padding: 40px 30px 20px;">
          <span style="font-family: #{@brand_font}; font-size: 28px; letter-spacing: 4px; color: #{@brand_dark_green};">PAVOI</span>
        </div>

        <!-- Main Content -->
        <div style="padding: 0 40px 40px;">
          <h1 style="font-family: #{@brand_font}; color: #{@brand_dark_green}; margin: 0 0 30px; font-size: 26px; font-weight: normal; text-align: center; letter-spacing: 1px;">
            Welcome to the<br>Pavoi Creator Program
          </h1>

          <p style="margin: 0 0 20px;">#{html_escape(greeting(name))}!</p>

          <p style="margin: 0 0 20px;">You've been selected for the Pavoi Creator Program - and yes, that means <strong>jewelry samples</strong> are coming your way.</p>

          <p style="margin: 0 0 15px;"><strong>Here's what you get:</strong></p>

          <ul style="padding-left: 20px; margin: 0 0 25px;">
            <li style="margin-bottom: 8px;"><strong>Product samples</strong> shipped directly to you</li>
            <li style="margin-bottom: 8px;"><strong>Earn commissions</strong> on every sale from your content</li>
            <li style="margin-bottom: 8px;"><strong>First access</strong> to new drops before anyone else</li>
            <li style="margin-bottom: 8px;"><strong>Direct line</strong> to our team for collabs and support</li>
          </ul>

          <p style="margin: 0 0 20px;"><strong>Ready to join our exclusive creator community?</strong></p>

          <div style="text-align: center; margin: 30px 0;">
            <a href="#{html_escape(join_url)}"
               style="display: inline-block; background: #{@brand_dark_green}; color: #ffffff; padding: 16px 40px; text-decoration: none; font-size: 15px; letter-spacing: 1px; font-family: #{@brand_font};">
              JOIN THE COMMUNITY
            </a>
          </div>

          <div style="border-top: 1px solid #{@brand_sage}; margin-top: 35px; padding-top: 25px;">
            <p style="margin: 0;">
              Talk soon,<br>
              <strong>The Pavoi Team</strong>
            </p>
          </div>
        </div>

        <!-- Footer -->
        <div style="text-align: center; padding: 20px 30px; background: #f9f9f9; border-top: 1px solid #eee;">
          <p style="margin: 0 0 10px; color: #888; font-size: 12px;">
            You're receiving this email because you received a product sample from us on TikTok Shop.
          </p>
          <p style="margin: 0 0 10px; color: #888; font-size: 12px;">
            Pavoi &bull; 11401 NW 12th Street, Miami, FL 33172
          </p>
          <p style="margin: 0; color: #888; font-size: 12px;">
            <a href="#{html_escape(unsubscribe_url)}" style="color: #888; text-decoration: underline;">Unsubscribe</a>
          </p>
        </div>
      </div>
    </body>
    </html>
    """
  end

  @doc """
  Returns the welcome email plain text body.

  The join_url parameter is the URL to the consent/join form page.
  """
  def welcome_email_text(creator, join_url) do
    name = get_display_name(creator)
    unsubscribe_url = unsubscribe_url(creator)

    """
    Welcome to the Pavoi Creator Program

    #{greeting(name)}!

    You've been selected for the Pavoi Creator Program - and yes, that means jewelry samples are coming your way.

    Here's what you get:
    - Product samples shipped directly to you
    - Earn commissions on every sale from your content
    - First access to new drops before anyone else
    - Direct line to our team for collabs and support

    Ready to join our exclusive creator community? Click here:
    #{join_url}

    Talk soon,
    The Pavoi Team

    ---
    You're receiving this email because you received a product sample from us on TikTok Shop.
    Pavoi - 11401 NW 12th Street, Miami, FL 33172
    Unsubscribe: #{unsubscribe_url}
    """
  end

  @doc """
  Returns the welcome SMS body.

  Note: SMS has a 160 character limit for single messages.
  Longer messages are split and may cost more.
  """
  def welcome_sms_body(creator, lark_invite_url) do
    name = get_display_name(creator)
    hi = if name, do: "Hi #{name}!", else: "Hi!"

    # Keep it concise for SMS (under 160 chars if possible)
    "#{hi} Thanks for joining Pavoi as a creator. Join our exclusive Lark community for tips, early access & support: #{lark_invite_url}"
  end

  # Private helpers

  defp get_display_name(creator) do
    # Check each name source, filtering out any that contain asterisks (obscured data)
    clean_name(Creator.full_name(creator)) ||
      clean_name(creator.first_name) ||
      clean_name(creator.tiktok_username)
  end

  # Returns nil if name is nil or contains asterisks (obscured/redacted data)
  defp clean_name(nil), do: nil

  defp clean_name(name) when is_binary(name) do
    if String.contains?(name, "*"), do: nil, else: name
  end

  defp greeting(nil), do: "Hey there"
  defp greeting(name), do: "Hey #{name}"

  defp html_escape(nil), do: ""

  defp html_escape(string) when is_binary(string) do
    string
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp base_url do
    PavoiWeb.Endpoint.url()
  end

  defp unsubscribe_url(creator) do
    token = Pavoi.Outreach.generate_unsubscribe_token(creator.id)
    "#{base_url()}/unsubscribe/#{token}"
  end
end
