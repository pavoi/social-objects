defmodule PavoiWeb.AdminLive.Brands do
  @moduledoc """
  Admin page for listing and managing all brands.
  Includes brand settings modal for editing individual brand configuration.
  """
  use PavoiWeb, :live_view

  import PavoiWeb.AdminComponents

  alias Pavoi.Catalog
  alias Pavoi.Settings
  alias Pavoi.TiktokShop
  alias Phoenix.LiveView.JS

  # Keys that contain sensitive data and should be masked
  @secret_keys ~w(slack_bot_token bigquery_private_key shopify_client_secret)

  @impl true
  def mount(_params, _session, socket) do
    brands = Catalog.list_brands()

    {:ok,
     socket
     |> assign(:page_title, "Brands")
     |> assign(:brands, brands)
     |> assign(:selected_brand, nil)
     |> assign(:form, nil)
     |> assign(:secrets_configured, MapSet.new())
     |> assign(:visible_secrets, MapSet.new())
     |> assign(:tiktok_oauth_url, nil)}
  end

  @impl true
  def handle_event("edit_brand", %{"brand_id" => brand_id}, socket) do
    brand = Catalog.get_brand!(brand_id)
    settings = load_settings(brand)

    {:noreply,
     socket
     |> assign(:selected_brand, brand)
     |> assign(:form, to_form(settings, as: "settings"))
     |> assign(:secrets_configured, secrets_configured(settings))
     |> assign(:visible_secrets, MapSet.new())
     |> assign(:tiktok_oauth_url, TiktokShop.generate_authorization_url(brand.id))}
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_brand, nil)
     |> assign(:form, nil)
     |> assign(:secrets_configured, MapSet.new())
     |> assign(:visible_secrets, MapSet.new())
     |> assign(:tiktok_oauth_url, nil)}
  end

  @impl true
  def handle_event("save_brand_settings", %{"settings" => params}, socket) do
    brand = socket.assigns.selected_brand

    domain = normalize_domain(params["primary_domain"])

    case Catalog.update_brand(brand, %{primary_domain: domain}) do
      {:ok, updated_brand} ->
        update_settings(updated_brand.id, params)
        settings = load_settings(updated_brand)

        # Update brands list
        brands = update_brand_in_list(socket.assigns.brands, updated_brand)

        {:noreply,
         socket
         |> assign(:brands, brands)
         |> assign(:selected_brand, updated_brand)
         |> assign(:form, to_form(settings, as: "settings"))
         |> assign(:secrets_configured, secrets_configured(settings))
         |> put_flash(:info, "Brand settings saved.")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(params, as: "settings"))
         |> put_flash(:error, "Unable to update brand settings. Please check the domain.")}
    end
  end

  @impl true
  def handle_event("toggle_secret_visibility", %{"key" => key}, socket) do
    visible_secrets = socket.assigns.visible_secrets

    new_visible =
      if MapSet.member?(visible_secrets, key) do
        MapSet.delete(visible_secrets, key)
      else
        MapSet.put(visible_secrets, key)
      end

    {:noreply, assign(socket, :visible_secrets, new_visible)}
  end

  defp update_brand_in_list(brands, updated_brand) do
    Enum.map(brands, fn brand ->
      if brand.id == updated_brand.id, do: updated_brand, else: brand
    end)
  end

  # Load settings using the getter functions that fall back to env vars
  defp load_settings(brand) do
    brand_id = brand.id

    settings_getters = [
      {"sendgrid_from_name", &Settings.get_sendgrid_from_name/1},
      {"sendgrid_from_email", &Settings.get_sendgrid_from_email/1},
      {"slack_channel", &Settings.get_slack_channel/1},
      {"slack_bot_token", &Settings.get_slack_bot_token/1},
      {"slack_dev_user_id", &Settings.get_slack_dev_user_id/1},
      {"bigquery_project_id", &Settings.get_bigquery_project_id/1},
      {"bigquery_dataset", &Settings.get_bigquery_dataset/1},
      {"bigquery_service_account_email", &Settings.get_bigquery_service_account_email/1},
      {"bigquery_private_key", &Settings.get_bigquery_private_key/1},
      {"shopify_store_name", &Settings.get_shopify_store_name/1},
      {"shopify_client_id", &Settings.get_shopify_client_id/1},
      {"shopify_client_secret", &Settings.get_shopify_client_secret/1}
    ]

    base_settings = %{
      "primary_domain" => brand.primary_domain || "",
      "tiktok_live_accounts" =>
        format_tiktok_accounts(Settings.get_tiktok_live_accounts(brand_id))
    }

    Enum.reduce(settings_getters, base_settings, fn {key, getter}, acc ->
      Map.put(acc, key, getter.(brand_id) || "")
    end)
  end

  defp format_tiktok_accounts(accounts) when is_list(accounts), do: Enum.join(accounts, ", ")
  defp format_tiktok_accounts(_), do: ""

  defp secrets_configured(settings) do
    @secret_keys
    |> Enum.filter(fn key -> settings[key] != "" end)
    |> MapSet.new()
  end

  defp update_settings(brand_id, params) do
    Settings.put_setting(brand_id, "sendgrid_from_name", params["sendgrid_from_name"])
    Settings.put_setting(brand_id, "sendgrid_from_email", params["sendgrid_from_email"])
    Settings.put_setting(brand_id, "slack_channel", params["slack_channel"])
    Settings.put_setting(brand_id, "slack_bot_token", params["slack_bot_token"])
    Settings.put_setting(brand_id, "slack_dev_user_id", params["slack_dev_user_id"])
    Settings.put_setting(brand_id, "bigquery_project_id", params["bigquery_project_id"])
    Settings.put_setting(brand_id, "bigquery_dataset", params["bigquery_dataset"])

    Settings.put_setting(
      brand_id,
      "bigquery_service_account_email",
      params["bigquery_service_account_email"]
    )

    Settings.put_setting(brand_id, "bigquery_private_key", params["bigquery_private_key"])
    Settings.put_setting(brand_id, "shopify_store_name", params["shopify_store_name"])
    Settings.put_setting(brand_id, "shopify_client_id", params["shopify_client_id"])
    Settings.put_setting(brand_id, "shopify_client_secret", params["shopify_client_secret"])
    Settings.put_setting(brand_id, "tiktok_live_accounts", params["tiktok_live_accounts"])
  end

  defp normalize_domain(nil), do: nil

  defp normalize_domain(domain) do
    domain = domain |> String.trim() |> String.downcase()
    if domain == "", do: nil, else: domain
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="admin-page">
      <div class="admin-page__header">
        <h1 class="admin-page__title">Brands</h1>
      </div>

      <div class="admin-panel">
        <div class="admin-panel__body--flush">
          <.admin_table id="brands-table" rows={@brands} row_id={fn brand -> "brand-#{brand.id}" end}>
            <:col :let={brand} label="Name">
              {brand.name}
            </:col>
            <:col :let={brand} label="Slug">
              <code>{brand.slug}</code>
            </:col>
            <:col :let={brand} label="Primary Domain">
              {brand.primary_domain || "-"}
            </:col>
            <:action :let={brand}>
              <.button
                phx-click="edit_brand"
                phx-value-brand_id={brand.id}
                size="sm"
                variant="outline"
              >
                Settings
              </.button>
            </:action>
          </.admin_table>
        </div>
      </div>

      <.brand_settings_modal
        :if={@selected_brand}
        brand={@selected_brand}
        form={@form}
        secrets_configured={@secrets_configured}
        visible_secrets={@visible_secrets}
        tiktok_oauth_url={@tiktok_oauth_url}
        on_cancel={JS.push("close_modal")}
      />
    </div>
    """
  end
end
