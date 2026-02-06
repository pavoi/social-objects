defmodule PavoiWeb.AdminComponents do
  @moduledoc """
  UI components for the admin dashboard.
  """

  use Phoenix.Component
  use PavoiWeb, :verified_routes

  import PavoiWeb.CoreComponents, only: [button: 1, input: 1, modal: 1, secret_input: 1]

  @doc """
  Renders a stat card for the dashboard.
  """
  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :href, :string, default: nil

  def stat_card(assigns) do
    ~H"""
    <div class="stat-card">
      <div class="stat-card__value">{@value}</div>
      <div class="stat-card__label">{@label}</div>
      <a :if={@href} href={@href} class="stat-card__link">View all</a>
    </div>
    """
  end

  @doc """
  Renders a simple data table for admin lists.
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil

  slot :col, required: true do
    attr :label, :string
  end

  slot :action

  def admin_table(assigns) do
    ~H"""
    <div class="admin-panel">
      <div class="admin-panel__body--flush">
        <table class="admin-table">
          <thead>
            <tr>
              <th :for={col <- @col}>{col[:label]}</th>
              <th :if={@action != []}>Actions</th>
            </tr>
          </thead>
          <tbody id={@id}>
            <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
              <td :for={col <- @col}>
                {render_slot(col, row)}
              </td>
              <td :if={@action != []}>
                <div class="admin-table__actions">
                  {render_slot(@action, row)}
                </div>
              </td>
            </tr>
            <tr :if={@rows == []}>
              <td
                colspan={length(@col) + if(@action != [], do: 1, else: 0)}
                class="admin-table__empty"
              >
                No data
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  @doc """
  Renders a badge/pill for status display.
  """
  attr :variant, :atom, default: :default
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span class={"badge badge--#{@variant}"}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  User detail modal for viewing/editing a user.
  """
  attr :user, :map, required: true
  attr :last_session_at, :any, default: nil
  attr :on_cancel, :any, required: true

  def user_detail_modal(assigns) do
    ~H"""
    <.modal id="user-detail-modal" show={true} on_cancel={@on_cancel} modal_class="modal__box--wide">
      <div class="modal__header">
        <h2 class="modal__title">{@user.email}</h2>
      </div>
      <div class="modal__body">
        <div class="admin-detail__grid">
          <div class="admin-panel">
            <div class="admin-panel__header">
              <h3 class="admin-panel__title">User Information</h3>
            </div>
            <div class="admin-panel__body">
              <div class="admin-detail__field">
                <span class="admin-detail__label">Email</span>
                <span class="admin-detail__value">{@user.email}</span>
              </div>
              <div class="admin-detail__field">
                <span class="admin-detail__label">Admin Status</span>
                <span class="admin-detail__value">
                  <.badge :if={@user.is_admin} variant={:primary}>Admin</.badge>
                  <span :if={!@user.is_admin}>Not an admin</span>
                </span>
              </div>
              <div class="admin-detail__field">
                <span class="admin-detail__label">Email Confirmed</span>
                <span class="admin-detail__value">
                  {if @user.confirmed_at,
                    do: format_datetime(@user.confirmed_at),
                    else: "Not confirmed"}
                </span>
              </div>
              <div class="admin-detail__field">
                <span class="admin-detail__label">Last Session</span>
                <span class="admin-detail__value">{format_datetime(@last_session_at)}</span>
              </div>
              <div class="admin-detail__field">
                <span class="admin-detail__label">Created</span>
                <span class="admin-detail__value">{format_datetime(@user.inserted_at)}</span>
              </div>
            </div>
          </div>

          <div class="admin-panel">
            <div class="admin-panel__header">
              <h3 class="admin-panel__title">Actions</h3>
            </div>
            <div class="admin-panel__body">
              <div class="quick-actions">
                <.button
                  phx-click="toggle_admin"
                  phx-value-user_id={@user.id}
                  variant={if @user.is_admin, do: "outline", else: "primary"}
                >
                  {if @user.is_admin, do: "Remove Admin", else: "Make Admin"}
                </.button>
              </div>
            </div>
          </div>
        </div>

        <div class="admin-panel" style="margin-top: var(--space-4);">
          <div class="admin-panel__header">
            <h3 class="admin-panel__title">Brand Memberships</h3>
          </div>
          <div class="admin-panel__body--flush">
            <table class="admin-table">
              <thead>
                <tr>
                  <th>Brand</th>
                  <th>Role</th>
                  <th>Joined</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={ub <- @user.user_brands}>
                  <td>{ub.brand.name}</td>
                  <td>
                    <.badge variant={role_variant(ub.role)}>{ub.role}</.badge>
                  </td>
                  <td>{format_datetime(ub.inserted_at)}</td>
                  <td>
                    <.button
                      phx-click="remove_from_brand"
                      phx-value-user_id={@user.id}
                      phx-value-brand_id={ub.brand.id}
                      size="sm"
                      variant="outline"
                      data-confirm={"Remove #{@user.email} from #{ub.brand.name}?"}
                    >
                      Remove
                    </.button>
                  </td>
                </tr>
                <tr :if={@user.user_brands == []}>
                  <td colspan="4" class="admin-table__empty">No brand memberships</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </.modal>
    """
  end

  @doc """
  Brand settings modal for editing brand configuration.
  """
  attr :brand, :map, required: true
  attr :form, :any, required: true
  attr :secrets_configured, :any, required: true
  attr :visible_secrets, :any, required: true
  attr :tiktok_oauth_url, :string, required: true
  attr :on_cancel, :any, required: true

  def brand_settings_modal(assigns) do
    ~H"""
    <.modal
      id="brand-settings-modal"
      show={true}
      on_cancel={@on_cancel}
      modal_class="modal__box--wide"
    >
      <div class="modal__header">
        <h2 class="modal__title">{@brand.name} Settings</h2>
      </div>
      <div class="modal__body">
        <.form
          for={@form}
          id="brand-settings-form"
          phx-submit="save_brand_settings"
          class="settings-page"
        >
          <section class="settings-section">
            <div class="settings-section__header">
              <h2 class="settings-section__title">Domain</h2>
              <p class="settings-section__description">Configure your brand's custom domain.</p>
            </div>
            <div class="settings-grid">
              <.input
                field={@form[:primary_domain]}
                type="text"
                label="Primary Domain"
                placeholder="brand.com"
              />
            </div>
          </section>

          <section class="settings-section">
            <div class="settings-section__header">
              <h2 class="settings-section__title">SendGrid</h2>
              <p class="settings-section__description">
                Email sending configuration for outreach and notifications.
              </p>
            </div>
            <div class="settings-grid">
              <.input
                field={@form[:sendgrid_from_name]}
                type="text"
                label="From Name"
                placeholder="Brand Name"
              />
              <.input
                field={@form[:sendgrid_from_email]}
                type="email"
                label="From Email"
                placeholder="noreply@example.com"
              />
            </div>
          </section>

          <section class="settings-section">
            <div class="settings-section__header">
              <h2 class="settings-section__title">Slack</h2>
              <p class="settings-section__description">
                Slack integration for alerts and notifications.
              </p>
            </div>
            <div class="settings-grid">
              <.input
                field={@form[:slack_channel]}
                type="text"
                label="Channel"
                placeholder="#alerts"
              />
              <.secret_input
                field={@form[:slack_bot_token]}
                key="slack_bot_token"
                label="Bot Token"
                placeholder="xoxb-..."
                configured={secret_configured?(@secrets_configured, "slack_bot_token")}
                visible={secret_visible?(@visible_secrets, "slack_bot_token")}
              />
              <.input
                field={@form[:slack_dev_user_id]}
                type="text"
                label="Dev User ID"
                placeholder="U12345678"
              />
            </div>
          </section>

          <section class="settings-section">
            <div class="settings-section__header">
              <h2 class="settings-section__title">BigQuery</h2>
              <p class="settings-section__description">
                Google BigQuery connection for order data sync.
              </p>
            </div>
            <div class="settings-grid">
              <.input
                field={@form[:bigquery_project_id]}
                type="text"
                label="Project ID"
                placeholder="my-gcp-project"
              />
              <.input
                field={@form[:bigquery_dataset]}
                type="text"
                label="Dataset"
                placeholder="project.dataset"
              />
              <.input
                field={@form[:bigquery_service_account_email]}
                type="email"
                label="Service Account Email"
                placeholder="svc@project.iam.gserviceaccount.com"
              />
              <div class="settings-field settings-field--full">
                <.secret_input
                  field={@form[:bigquery_private_key]}
                  key="bigquery_private_key"
                  label="Private Key"
                  placeholder="-----BEGIN PRIVATE KEY-----"
                  configured={secret_configured?(@secrets_configured, "bigquery_private_key")}
                  visible={secret_visible?(@visible_secrets, "bigquery_private_key")}
                  multiline={true}
                />
              </div>
            </div>
          </section>

          <section class="settings-section">
            <div class="settings-section__header">
              <h2 class="settings-section__title">Shopify</h2>
              <p class="settings-section__description">Shopify store connection for product sync.</p>
            </div>
            <div class="settings-grid">
              <.input
                field={@form[:shopify_store_name]}
                type="text"
                label="Store Name"
                placeholder="your-store"
              />
              <.input
                field={@form[:shopify_client_id]}
                type="text"
                label="Client ID"
                placeholder="shopify-client-id"
              />
              <.secret_input
                field={@form[:shopify_client_secret]}
                key="shopify_client_secret"
                label="Client Secret"
                placeholder="shopify-client-secret"
                configured={secret_configured?(@secrets_configured, "shopify_client_secret")}
                visible={secret_visible?(@visible_secrets, "shopify_client_secret")}
              />
            </div>
          </section>

          <section class="settings-section">
            <div class="settings-section__header">
              <h2 class="settings-section__title">TikTok</h2>
              <p class="settings-section__description">TikTok Shop and live stream monitoring.</p>
            </div>
            <div class="settings-grid">
              <.input
                field={@form[:tiktok_live_accounts]}
                type="text"
                label="Live Monitor Accounts"
                placeholder="username1, username2"
              />
            </div>
            <div class="settings-actions">
              <a href={@tiktok_oauth_url} class="button button--outline" target="_blank">
                Connect TikTok Shop
              </a>
              <span class="settings-actions__hint">Opens TikTok authorization in a new tab.</span>
            </div>
          </section>
        </.form>
      </div>
      <div class="modal__footer">
        <.button variant="outline" phx-click={@on_cancel}>Cancel</.button>
        <.button
          variant="primary"
          form="brand-settings-form"
          type="submit"
          phx-disable-with="Saving..."
        >
          Save Settings
        </.button>
      </div>
    </.modal>
    """
  end

  # Helper functions
  defp format_datetime(nil), do: "-"
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %d, %Y %H:%M")
  defp format_datetime(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%b %d, %Y %H:%M")

  defp role_variant("owner"), do: :primary
  defp role_variant("admin"), do: :success
  defp role_variant(_), do: :default

  def secret_configured?(secrets_configured, key), do: MapSet.member?(secrets_configured, key)
  def secret_visible?(visible_secrets, key), do: MapSet.member?(visible_secrets, key)
end
