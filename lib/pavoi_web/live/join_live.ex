defmodule PavoiWeb.JoinLive do
  @moduledoc """
  LiveView for the creator join/SMS consent form.

  This is a public page (no auth required) accessed from email links.
  It captures phone number and SMS consent before redirecting to Lark.
  """
  use PavoiWeb, :live_view

  alias Pavoi.Creators
  alias Pavoi.Outreach
  alias Pavoi.Settings

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    # Capture client info during mount for TCPA compliance (connect_info only available here)
    {client_ip, user_agent} = get_client_info(socket)

    case Outreach.verify_join_token(token) do
      {:ok, %{creator_id: creator_id, lark_preset: lark_preset}} ->
        creator = Creators.get_creator!(creator_id)
        lark_url = get_lark_url(lark_preset)

        {:ok,
         socket
         |> assign(:page_title, "Join the Pavoi Creator Program")
         |> assign(:creator, creator)
         |> assign(:lark_preset, lark_preset)
         |> assign(:lark_url, lark_url)
         |> assign(:phone, creator.phone || "")
         |> assign(:phone_error, nil)
         |> assign(:submitting, false)
         |> assign(:client_ip, client_ip)
         |> assign(:user_agent, user_agent)}

      {:error, :expired} ->
        {:ok,
         socket
         |> assign(:page_title, "Link Expired")
         |> assign(:error, "This link has expired. Please contact us for a new invitation.")}

      {:error, _} ->
        {:ok,
         socket
         |> assign(:page_title, "Invalid Link")
         |> assign(:error, "This link is invalid. Please check your email for the correct link.")}
    end
  end

  @impl true
  def handle_event("validate", %{"phone" => phone}, socket) do
    {:noreply, assign(socket, :phone, phone)}
  end

  @impl true
  def handle_event("submit", %{"phone" => phone}, socket) do
    phone = String.trim(phone)
    lark_url = socket.assigns.lark_url

    with :ok <- validate_lark_url(lark_url),
         :ok <- validate_phone(phone),
         {:ok, _creator} <- save_consent(socket, phone) do
      {:noreply, redirect(socket, external: lark_url)}
    else
      {:error, :no_lark_url} ->
        {:noreply, assign(socket, :phone_error, "Lark community link not configured. Please contact support.")}

      {:error, :save_failed} ->
        {:noreply, assign(socket, :phone_error, "Something went wrong. Please try again.")}

      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, :phone_error, message)}
    end
  end

  defp validate_lark_url(url) when url == "" or is_nil(url), do: {:error, :no_lark_url}
  defp validate_lark_url(_url), do: :ok

  defp save_consent(socket, phone) do
    case Outreach.update_sms_consent_with_tracking(
           socket.assigns.creator,
           phone,
           socket.assigns.client_ip,
           socket.assigns.user_agent
         ) do
      {:ok, creator} -> {:ok, creator}
      {:error, _changeset} -> {:error, :save_failed}
    end
  end

  defp validate_phone(phone) do
    # Remove all non-digit characters for validation
    digits = String.replace(phone, ~r/\D/, "")

    cond do
      String.length(digits) < 10 ->
        {:error, "Please enter a valid 10-digit phone number."}

      String.length(digits) > 11 ->
        {:error, "Phone number is too long. Please enter a US phone number."}

      String.length(digits) == 11 and not String.starts_with?(digits, "1") ->
        {:error, "Please enter a valid US phone number."}

      true ->
        :ok
    end
  end

  # Default Lark invite URLs (same as CreatorsLive.Index)
  @lark_defaults %{
    "jewelry" =>
      "https://applink.larksuite.com/client/chat/chatter/add_by_link?link_token=381ve559-aa4d-4a1d-9412-6bee35821e1i",
    "active" =>
      "https://applink.larksuite.com/client/chat/chatter/add_by_link?link_token=308u55cf-7f36-4516-a0b7-a102361a1c2n",
    "top_creators" =>
      "https://applink.larksuite.com/client/chat/chatter/add_by_link?link_token=3c9q707a-24bf-449a-9ee9-aef46e73e7es"
  }

  defp get_lark_url(lark_preset) do
    setting_key = "lark_preset_#{lark_preset}"
    Settings.get_setting(setting_key) || Map.get(@lark_defaults, lark_preset, "")
  end

  defp get_client_info(socket) do
    if connected?(socket) do
      peer_data = get_connect_info(socket, :peer_data)
      user_agent = get_connect_info(socket, :user_agent) || "Unknown"
      ip = if peer_data, do: format_ip(peer_data[:address]), else: "Unknown"
      {ip, user_agent}
    else
      # During initial static render, connect_info isn't available
      {"Unknown", "Unknown"}
    end
  end

  defp format_ip(nil), do: "Unknown"
  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip) when is_binary(ip), do: ip
  defp format_ip(_), do: "Unknown"

  @impl true
  def render(assigns) do
    if Map.has_key?(assigns, :error) do
      render_error(assigns)
    else
      render_form(assigns)
    end
  end

  defp render_error(assigns) do
    ~H"""
    <div class="join-page join-page--error">
      <div class="join-container">
        <div class="join-header">
          <span class="join-logo">PAVOI</span>
        </div>
        <div class="join-content">
          <h1>Oops!</h1>
          <p class="join-error-message">{@error}</p>
        </div>
      </div>
    </div>
    """
  end

  defp render_form(assigns) do
    ~H"""
    <div class="join-page">
      <div class="join-container">
        <div class="join-header">
          <span class="join-logo">PAVOI</span>
        </div>

        <div class="join-content">
          <h1>Join the Pavoi Creator Program</h1>

          <div class="join-benefits">
            <p>Get access to:</p>
            <ul>
              <li><strong>Free product samples</strong> shipped directly to you</li>
              <li><strong>Competitive commissions</strong> on every sale from your content</li>
              <li><strong>Early access</strong> to new drops before anyone else</li>
              <li><strong>Direct support</strong> from our team for collabs and questions</li>
            </ul>
          </div>

          <div class="join-lark-info">
            <p>
              We use <strong>Lark</strong>
              (a free messaging app by ByteDance, TikTok's parent company)
              for our creator community. After submitting this form, you'll be redirected to join our Lark group.
            </p>
          </div>

          <form phx-submit="submit" phx-change="validate" class="join-form">
            <div class="join-field">
              <label for="email">Email</label>
              <input
                type="email"
                id="email"
                value={@creator.email}
                readonly
                class="join-input join-input--readonly"
              />
            </div>

            <div class="join-field">
              <label for="phone">Phone Number</label>
              <input
                type="tel"
                id="phone"
                name="phone"
                value={@phone}
                placeholder="(555) 123-4567"
                class={"join-input #{if @phone_error, do: "join-input--error"}"}
                required
                autofocus
              />
              <span :if={@phone_error} class="join-field-error">{@phone_error}</span>
            </div>

            <p class="join-consent-text">
              By clicking "Join the Program", you consent to receive SMS messages from Pavoi
              at the phone number provided. Message frequency varies. Msg &amp; data rates may apply.
              Reply STOP to unsubscribe.
            </p>

            <button type="submit" class="join-button" disabled={@submitting}>
              {if @submitting, do: "Joining...", else: "JOIN THE PROGRAM"}
            </button>
          </form>
        </div>
      </div>
    </div>
    """
  end
end
