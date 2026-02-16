defmodule SocialObjectsWeb.AdminLive.Brands do
  @moduledoc """
  Admin page for listing and managing all brands.
  Includes brand settings modal for editing individual brand configuration.
  """
  use SocialObjectsWeb, :live_view

  import SocialObjectsWeb.AdminComponents

  alias Phoenix.LiveView.JS
  alias SocialObjects.Catalog
  alias SocialObjects.Catalog.Brand
  alias SocialObjects.Settings
  alias SocialObjects.TiktokShop

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
     |> assign(:shared_shopify_brands, [])
     |> assign(:tiktok_oauth_url, nil)
     |> assign(:tiktok_auth, nil)
     |> assign(:tiktok_shop_region, "US")
     |> assign(:new_brand_form, nil)}
  end

  @impl true
  def handle_event("edit_brand", %{"brand_id" => brand_id}, socket) do
    brand = Catalog.get_brand!(brand_id)
    settings = load_settings(brand)
    shared_shopify_brands = find_shared_shopify_brands(brand, socket.assigns.brands, settings)
    tiktok_auth = TiktokShop.get_auth(brand.id)
    region = socket.assigns.tiktok_shop_region

    {:noreply,
     socket
     |> assign(:selected_brand, brand)
     |> assign(:form, to_form(settings, as: "settings"))
     |> assign(:secrets_configured, secrets_configured(settings))
     |> assign(:visible_secrets, MapSet.new())
     |> assign(:shared_shopify_brands, shared_shopify_brands)
     |> assign(:tiktok_oauth_url, tiktok_authorize_url(brand.id, region))
     |> assign(:tiktok_auth, tiktok_auth)}
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_brand, nil)
     |> assign(:form, nil)
     |> assign(:secrets_configured, MapSet.new())
     |> assign(:visible_secrets, MapSet.new())
     |> assign(:shared_shopify_brands, [])
     |> assign(:tiktok_oauth_url, nil)
     |> assign(:tiktok_auth, nil)}
  end

  @impl true
  def handle_event("save_brand_settings", %{"settings" => params}, socket) do
    brand = socket.assigns.selected_brand

    domain = normalize_domain(params["primary_domain"])

    case Catalog.update_brand(brand, %{primary_domain: domain}) do
      {:ok, updated_brand} ->
        _ = update_settings(updated_brand.id, params)
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

  @impl true
  def handle_event("set_tiktok_region", %{"region" => region}, socket) do
    brand = socket.assigns.selected_brand

    {:noreply,
     socket
     |> assign(:tiktok_shop_region, region)
     |> assign(:tiktok_oauth_url, tiktok_authorize_url(brand.id, region))}
  end

  @impl true
  def handle_event("new_brand", _params, socket) do
    changeset = Brand.changeset(%Brand{}, %{})
    {:noreply, assign(socket, :new_brand_form, to_form(changeset))}
  end

  @impl true
  def handle_event("close_new_brand_modal", _params, socket) do
    {:noreply, assign(socket, :new_brand_form, nil)}
  end

  @impl true
  def handle_event("validate_new_brand", %{"brand" => params}, socket) do
    changeset =
      %Brand{}
      |> Brand.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :new_brand_form, to_form(changeset))}
  end

  @impl true
  def handle_event("create_brand", %{"brand" => params}, socket) do
    # Auto-generate slug from name if not provided
    params = ensure_slug(params)

    case Catalog.create_brand(params) do
      {:ok, brand} ->
        {:noreply,
         socket
         |> assign(:brands, socket.assigns.brands ++ [brand])
         |> assign(:new_brand_form, nil)
         |> put_flash(
           :info,
           "Brand \"#{brand.name}\" created. Click Settings to configure integrations."
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, :new_brand_form, to_form(changeset))}
    end
  end

  defp ensure_slug(%{"slug" => slug} = params) when slug != "" and not is_nil(slug), do: params

  defp ensure_slug(%{"name" => name} = params) when is_binary(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s-]/, "")
      |> String.replace(~r/\s+/, "-")
      |> String.trim("-")

    Map.put(params, "slug", slug)
  end

  defp ensure_slug(params), do: params

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
        format_tiktok_accounts(Settings.get_tiktok_live_accounts(brand_id)),
      "shopify_include_tags" => format_csv_list(Settings.get_shopify_include_tags(brand_id)),
      "shopify_exclude_tags" => format_csv_list(Settings.get_shopify_exclude_tags(brand_id)),
      "bigquery_source_include_prefix" =>
        Settings.get_bigquery_source_include_prefix(brand_id) || "",
      "bigquery_source_exclude_prefix" =>
        Settings.get_bigquery_source_exclude_prefix(brand_id) || ""
    }

    Enum.reduce(settings_getters, base_settings, fn {key, getter}, acc ->
      Map.put(acc, key, getter.(brand_id) || "")
    end)
  end

  defp format_tiktok_accounts(accounts) when is_list(accounts), do: Enum.join(accounts, ", ")

  defp format_csv_list(items), do: Enum.join(items, ", ")

  defp secrets_configured(settings) do
    @secret_keys
    |> Enum.filter(fn key -> settings[key] != "" end)
    |> MapSet.new()
  end

  defp update_settings(brand_id, params) do
    _ = Settings.put_setting(brand_id, "sendgrid_from_name", params["sendgrid_from_name"])
    _ = Settings.put_setting(brand_id, "sendgrid_from_email", params["sendgrid_from_email"])
    _ = Settings.put_setting(brand_id, "slack_channel", params["slack_channel"])
    _ = Settings.put_setting(brand_id, "slack_bot_token", params["slack_bot_token"])
    _ = Settings.put_setting(brand_id, "slack_dev_user_id", params["slack_dev_user_id"])
    _ = Settings.put_setting(brand_id, "bigquery_project_id", params["bigquery_project_id"])
    _ = Settings.put_setting(brand_id, "bigquery_dataset", params["bigquery_dataset"])

    _ =
      Settings.put_setting(
        brand_id,
        "bigquery_service_account_email",
        params["bigquery_service_account_email"]
      )

    _ = Settings.put_setting(brand_id, "bigquery_private_key", params["bigquery_private_key"])

    _ =
      Settings.put_setting(
        brand_id,
        "bigquery_source_include_prefix",
        params["bigquery_source_include_prefix"]
      )

    _ =
      Settings.put_setting(
        brand_id,
        "bigquery_source_exclude_prefix",
        params["bigquery_source_exclude_prefix"]
      )

    _ = Settings.put_setting(brand_id, "shopify_store_name", params["shopify_store_name"])
    _ = Settings.put_setting(brand_id, "shopify_client_id", params["shopify_client_id"])
    _ = Settings.put_setting(brand_id, "shopify_client_secret", params["shopify_client_secret"])
    _ = Settings.put_setting(brand_id, "shopify_include_tags", params["shopify_include_tags"])
    _ = Settings.put_setting(brand_id, "shopify_exclude_tags", params["shopify_exclude_tags"])
    _ = Settings.put_setting(brand_id, "tiktok_live_accounts", params["tiktok_live_accounts"])
  end

  defp normalize_domain(nil), do: nil

  defp normalize_domain(domain) do
    domain = domain |> String.trim() |> String.downcase()
    if domain == "", do: nil, else: domain
  end

  # Finds other brands that share the same Shopify store name
  defp find_shared_shopify_brands(current_brand, all_brands, current_settings) do
    store_name = current_settings["shopify_store_name"]

    if store_name == "" or is_nil(store_name) do
      []
    else
      all_brands
      |> Enum.reject(&(&1.id == current_brand.id))
      |> Enum.filter(fn brand ->
        Settings.get_shopify_store_name(brand.id) == store_name
      end)
    end
  end

  # Build URL to our TikTok authorize endpoint (stores brand_id in session before redirecting to TikTok)
  defp tiktok_authorize_url(brand_id, region) do
    "/tiktok/authorize?brand_id=#{brand_id}&region=#{region}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="admin-page">
      <div class="admin-page__header">
        <h1 class="admin-page__title">Brands</h1>
        <.button phx-click="new_brand" variant="primary">
          New Brand
        </.button>
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
        shared_shopify_brands={@shared_shopify_brands}
        tiktok_oauth_url={@tiktok_oauth_url}
        tiktok_auth={@tiktok_auth}
        tiktok_shop_region={@tiktok_shop_region}
        on_cancel={JS.push("close_modal")}
      />

      <.new_brand_modal
        :if={@new_brand_form}
        form={@new_brand_form}
        on_cancel={JS.push("close_new_brand_modal")}
      />
    </div>
    """
  end
end
