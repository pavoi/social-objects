defmodule PavoiWeb.JoinLive do
  @moduledoc """
  LiveView for the creator join/SMS consent form.

  This is a public page (no auth required) accessed from email links.
  It captures phone number and SMS consent before redirecting to Lark.

  Supports customizable page templates via GrapesJS. If a page template
  is configured for the lark_preset, it renders that template with the
  consent form injected. Otherwise, falls back to the hardcoded design.
  """
  use PavoiWeb, :live_view

  alias Pavoi.Catalog
  alias Pavoi.Communications
  alias Pavoi.Creators
  alias Pavoi.Outreach
  alias Pavoi.Settings

  @default_form_config %{
    "button_text" => "JOIN THE PROGRAM",
    "email_label" => "Email",
    "phone_label" => "Phone Number",
    "phone_placeholder" => "(555) 123-4567"
  }

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    # Capture client info during mount for TCPA compliance (connect_info only available here)
    {client_ip, user_agent} = get_client_info(socket)

    case Outreach.verify_join_token(token) do
      {:ok, %{brand_id: brand_id, creator_id: creator_id, lark_preset: lark_preset}} ->
        brand = Catalog.get_brand!(brand_id)
        creator = Creators.get_creator!(brand_id, creator_id)
        lark_url = get_lark_url(brand_id, lark_preset)

        # Load page template if configured
        {template_html, form_config} = load_page_template(brand_id, lark_preset)

        brand_name = brand.name || Settings.app_name()

        {:ok,
         socket
         |> assign(:page_title, "Join the #{brand_name} Creator Program")
         |> assign(:current_brand, brand)
         |> assign(:current_scope, nil)
         |> assign(:current_page, nil)
         |> assign(:brand_name, brand_name)
         |> assign(:creator, creator)
         |> assign(:lark_preset, lark_preset)
         |> assign(:lark_url, lark_url)
         |> assign(:phone, creator.phone || "")
         |> assign(:phone_error, nil)
         |> assign(:submitting, false)
         |> assign(:client_ip, client_ip)
         |> assign(:user_agent, user_agent)
         |> assign(:template_html, template_html)
         |> assign(:form_config, form_config)}

      {:error, :expired} ->
        {:ok,
         socket
         |> assign(:page_title, "Link Expired")
         |> assign(:current_brand, nil)
         |> assign(:current_scope, nil)
         |> assign(:current_page, nil)
         |> assign(:brand_name, Settings.app_name())
         |> assign(:error, "This link has expired. Please contact us for a new invitation.")}

      {:error, _} ->
        {:ok,
         socket
         |> assign(:page_title, "Invalid Link")
         |> assign(:current_brand, nil)
         |> assign(:current_scope, nil)
         |> assign(:current_page, nil)
         |> assign(:brand_name, Settings.app_name())
         |> assign(:error, "This link is invalid. Please check your email for the correct link.")}
    end
  end

  defp load_page_template(brand_id, lark_preset) do
    case Communications.get_default_page_template(brand_id, lark_preset) do
      nil ->
        # No template configured - use fallback
        {nil, @default_form_config}

      template ->
        # Merge template's form_config with defaults
        config = Map.merge(@default_form_config, template.form_config || %{})
        {template.html_body, config}
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
        {:noreply,
         assign(
           socket,
           :phone_error,
           "Lark community link not configured. Please contact support."
         )}

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

  defp get_lark_url(brand_id, lark_preset) do
    setting_key = "lark_preset_#{lark_preset}"
    Settings.get_setting(brand_id, setting_key) || Map.get(@lark_defaults, lark_preset, "")
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
    cond do
      Map.has_key?(assigns, :error) ->
        render_error(assigns)

      assigns.template_html ->
        render_with_template(assigns)

      true ->
        render_form(assigns)
    end
  end

  defp render_with_template(assigns) do
    # Split the template HTML at the consent form placeholder
    {before_form, after_form} = split_at_form_placeholder(assigns.template_html)
    assigns = Map.merge(assigns, %{before_form: before_form, after_form: after_form})

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_brand={@current_brand}
      current_page={@current_page}
    >
      <div class="join-page join-page--templated">
        {raw(@before_form)}
        <.consent_form
          creator={@creator}
          phone={@phone}
          phone_error={@phone_error}
          submitting={@submitting}
          form_config={@form_config}
          brand_name={@brand_name}
        />
        {raw(@after_form)}
      </div>
    </Layouts.app>
    """
  end

  defp split_at_form_placeholder(html) do
    # Find the consent form placeholder and split the HTML
    # The placeholder looks like: <div data-form-type="consent" ...>...</div>
    case Regex.run(
           ~r/(<div[^>]*data-form-type="consent"[^>]*>[\s\S]*?<\/div>)/i,
           html,
           return: :index
         ) do
      [{start_idx, length} | _] ->
        before = String.slice(html, 0, start_idx)
        after_form = String.slice(html, start_idx + length, String.length(html))
        {before, after_form}

      nil ->
        # No placeholder found - render template before form, nothing after
        {html, ""}
    end
  end

  # Consent form component - uses form_config for customizable text
  defp consent_form(assigns) do
    ~H"""
    <form phx-submit="submit" phx-change="validate" class="join-form">
      <div class="join-field">
        <label for="email">{@form_config["email_label"]}</label>
        <input
          type="email"
          id="email"
          value={@creator.email}
          readonly
          class="join-input join-input--readonly"
        />
      </div>

      <div class="join-field">
        <label for="phone">{@form_config["phone_label"]}</label>
        <input
          type="tel"
          id="phone"
          name="phone"
          value={@phone}
          placeholder={@form_config["phone_placeholder"]}
          class={"join-input #{if @phone_error, do: "join-input--error"}"}
          required
          autofocus
        />
        <span :if={@phone_error} class="join-field-error">{@phone_error}</span>
      </div>

      <p class="join-consent-text">
        By clicking "{@form_config["button_text"]}", you consent to receive SMS messages from {@brand_name} at the phone number provided. Message frequency varies. Msg &amp; data rates may apply.
        Reply STOP to unsubscribe.
      </p>

      <button type="submit" class="join-button" disabled={@submitting}>
        {if @submitting, do: "Joining...", else: @form_config["button_text"]}
      </button>
    </form>
    """
  end

  defp render_error(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_brand={@current_brand}
      current_page={@current_page}
    >
      <div class="join-page join-page--error">
        <div class="join-container">
          <div class="join-header">
            <span class="join-logo">{String.upcase(@brand_name)}</span>
          </div>
          <div class="join-content">
            <h1>Oops!</h1>
            <p class="join-error-message">{@error}</p>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp render_form(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_brand={@current_brand}
      current_page={@current_page}
    >
      <div class="join-page">
        <div class="join-container">
          <div class="join-header">
            <span class="join-logo">{String.upcase(@brand_name)}</span>
          </div>

          <div class="join-content">
            <h1>Join the {@brand_name} Creator Program</h1>

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
                By clicking "Join the Program", you consent to receive SMS messages from {@brand_name} at the phone number provided. Message frequency varies. Msg &amp; data rates may apply.
                Reply STOP to unsubscribe.
              </p>

              <button type="submit" class="join-button" disabled={@submitting}>
                {if @submitting, do: "Joining...", else: "JOIN THE PROGRAM"}
              </button>
            </form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
