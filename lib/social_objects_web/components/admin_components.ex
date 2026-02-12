defmodule SocialObjectsWeb.AdminComponents do
  @moduledoc """
  UI components for the admin dashboard.
  """

  use Phoenix.Component
  use SocialObjectsWeb, :verified_routes

  import SocialObjectsWeb.CoreComponents,
    only: [button: 1, input: 1, modal: 1, secret_input: 1, format_relative_time: 1]

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
  attr :current_user_id, :any, required: true
  attr :show_add_brand_form, :boolean, default: false
  attr :available_brands, :list, default: []
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
                <.button
                  phx-click="reset_password"
                  phx-value-user_id={@user.id}
                  variant="outline"
                  data-confirm={"Generate new temp password for #{@user.email}? This will invalidate all their sessions."}
                >
                  Reset Password
                </.button>
              </div>
            </div>
          </div>
        </div>

        <div class="admin-panel" style="margin-top: var(--space-4);">
          <div class="admin-panel__header admin-panel__header--with-action">
            <h3 class="admin-panel__title">Brand Memberships</h3>
            <.button
              :if={@available_brands != [] && !@show_add_brand_form}
              phx-click="show_add_brand_form"
              size="sm"
              variant="outline"
            >
              + Add Brand
            </.button>
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
                <.add_brand_form_row
                  :if={@show_add_brand_form}
                  available_brands={@available_brands}
                />
                <tr :for={ub <- @user.user_brands}>
                  <td>{ub.brand.name}</td>
                  <td>
                    <select
                      class="input input--sm"
                      phx-change="change_brand_role"
                      phx-value-user_id={@user.id}
                      phx-value-brand_id={ub.brand.id}
                      name="role"
                    >
                      <option value="viewer" selected={ub.role == :viewer}>viewer</option>
                      <option value="admin" selected={ub.role == :admin}>admin</option>
                      <option value="owner" selected={ub.role == :owner}>owner</option>
                    </select>
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
                <tr :if={@user.user_brands == [] && !@show_add_brand_form}>
                  <td colspan="4" class="admin-table__empty">No brand memberships</td>
                </tr>
              </tbody>
            </table>
            <div :if={@available_brands == [] && @user.user_brands != []} class="admin-panel__hint">
              Already member of all brands
            </div>
          </div>
        </div>

        <div class="admin-panel admin-panel--danger" style="margin-top: var(--space-4);">
          <div class="admin-panel__header">
            <h3 class="admin-panel__title">Danger Zone</h3>
          </div>
          <div class="admin-panel__body">
            <div class="danger-zone">
              <div class="danger-zone__description">
                <strong>Delete this user</strong>
                <p>
                  Once deleted, this action cannot be undone. All user data will be permanently removed.
                </p>
              </div>
              <.button
                phx-click="delete_user"
                data-confirm="Are you sure you want to delete this user? This action cannot be undone."
                variant="danger"
                disabled={@user.id == @current_user_id}
                title={if @user.id == @current_user_id, do: "You cannot delete yourself", else: nil}
              >
                Delete User
              </.button>
            </div>
          </div>
        </div>
      </div>
    </.modal>
    """
  end

  @doc """
  Inline form row for adding a brand membership.
  """
  attr :available_brands, :list, required: true

  def add_brand_form_row(assigns) do
    ~H"""
    <tr class="add-brand-form-row">
      <td colspan="4">
        <form id="add-brand-form" phx-submit="add_brand_membership" class="add-brand-form">
          <div class="add-brand-form__field">
            <select name="brand_id" class="input input--sm" required>
              <option value="">Select brand...</option>
              <option :for={brand <- @available_brands} value={brand.id}>{brand.name}</option>
            </select>
          </div>
          <div class="add-brand-form__field">
            <select name="role" class="input input--sm">
              <option value="viewer">viewer</option>
              <option value="admin">admin</option>
              <option value="owner">owner</option>
            </select>
          </div>
          <div class="add-brand-form__actions">
            <.button type="submit" size="sm" variant="primary">Save</.button>
            <.button type="button" phx-click="cancel_add_brand" size="sm" variant="outline">
              Cancel
            </.button>
          </div>
        </form>
      </td>
    </tr>
    """
  end

  @doc """
  Modal showing the new temp password after password reset.
  """
  attr :email, :string, required: true
  attr :temp_password, :string, required: true
  attr :on_close, :any, required: true

  def password_reset_result_modal(assigns) do
    ~H"""
    <.modal id="password-reset-modal" show={true} on_cancel={@on_close}>
      <div class="modal__header">
        <h2 class="modal__title">Password Reset</h2>
      </div>
      <div class="modal__body">
        <p style="margin-bottom: var(--space-4);">
          Password reset for <strong>{@email}</strong>
        </p>
        <div class="settings-field">
          <label class="input-label">New Temporary Password</label>
          <div class="temp-password-display">
            <code class="temp-password-code">{@temp_password}</code>
            <button
              type="button"
              class="button button--sm button--outline"
              phx-hook="CopyToClipboard"
              id="copy-reset-password"
              data-copy-text={@temp_password}
            >
              Copy
            </button>
          </div>
        </div>
        <p class="settings-hint" style="margin-top: var(--space-4);">
          Share this password with the user. They will be required to set a new password on next login.
          All existing sessions have been invalidated.
        </p>
      </div>
      <div class="modal__footer">
        <.button variant="primary" phx-click={@on_close}>Done</.button>
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
  attr :shared_shopify_brands, :list, default: []
  attr :tiktok_oauth_url, :string, required: true
  attr :tiktok_auth, :any, default: nil
  attr :tiktok_shop_region, :string, default: "US"
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
            <div :if={@shared_shopify_brands != []} class="settings-notice settings-notice--info">
              <span class="settings-notice__icon">ℹ️</span>
              <span class="settings-notice__text">
                Shared Shopify store with: <strong>{Enum.map_join(@shared_shopify_brands, ", ", & &1.name)}</strong>.
                Use tag filters below to sync different products to each brand.
              </span>
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
            <div class="settings-subsection">
              <h3 class="settings-subsection__title">Product Filters</h3>
              <p class="settings-subsection__description">
                Filter which products sync to this brand. Useful when multiple brands share one Shopify store.
              </p>
              <div class="settings-grid">
                <.input
                  field={@form[:shopify_include_tags]}
                  type="text"
                  label="Include Tags"
                  placeholder="active, featured"
                />
                <.input
                  field={@form[:shopify_exclude_tags]}
                  type="text"
                  label="Exclude Tags"
                  placeholder="discontinued, hidden"
                />
              </div>
              <p class="settings-hint">
                <strong>Include:</strong>
                Only sync products with at least one of these tags. <strong>Exclude:</strong>
                Skip products with any of these tags.
                Leave both empty to sync all products.
              </p>
            </div>
          </section>

          <section class="settings-section">
            <div class="settings-section__header">
              <h2 class="settings-section__title">TikTok</h2>
              <p class="settings-section__description">TikTok Shop and live stream monitoring.</p>
            </div>

            <div :if={@tiktok_auth} class="settings-status settings-status--connected">
              <div class="settings-status__header">
                <span class="settings-status__indicator"></span>
                <span class="settings-status__label">TikTok Shop Connected</span>
              </div>
              <dl class="settings-status__details">
                <div>
                  <dt>Shop Name</dt>
                  <dd>{@tiktok_auth.shop_name}</dd>
                </div>
                <div>
                  <dt>Shop ID</dt>
                  <dd><code>{@tiktok_auth.shop_id}</code></dd>
                </div>
                <div>
                  <dt>Region</dt>
                  <dd>{@tiktok_auth.region}</dd>
                </div>
                <div>
                  <dt>Token Expires</dt>
                  <dd>{format_datetime(@tiktok_auth.access_token_expires_at)}</dd>
                </div>
              </dl>
            </div>

            <div :if={is_nil(@tiktok_auth)} class="settings-status settings-status--disconnected">
              <div class="settings-status__header">
                <span class="settings-status__indicator"></span>
                <span class="settings-status__label">TikTok Shop Not Connected</span>
              </div>
              <p class="settings-status__hint">
                The TikTok Shop owner must authorize access using the link below.
              </p>
            </div>

            <div class="settings-grid">
              <.input
                field={@form[:tiktok_live_accounts]}
                type="text"
                label="Live Monitor Accounts"
                placeholder="username1, username2"
              />
            </div>
            <div :if={is_nil(@tiktok_auth)} class="settings-subsection">
              <h3 class="settings-subsection__title">Shop Region</h3>
              <p class="settings-subsection__description">
                Select the region for the TikTok Shop authorization. US shops use a different authorization endpoint than Global shops.
              </p>
              <div class="settings-actions">
                <button
                  type="button"
                  class={"button " <> if(@tiktok_shop_region == "US", do: "button--primary", else: "button--outline")}
                  phx-click="set_tiktok_region"
                  phx-value-region="US"
                >
                  US
                </button>
                <button
                  type="button"
                  class={"button " <> if(@tiktok_shop_region == "Global", do: "button--primary", else: "button--outline")}
                  phx-click="set_tiktok_region"
                  phx-value-region="Global"
                >
                  Global
                </button>
              </div>
            </div>
            <div class="settings-actions">
              <a href={@tiktok_oauth_url} class="button button--outline" target="_blank">
                {if @tiktok_auth, do: "Reconnect TikTok Shop", else: "Connect TikTok Shop"}
              </a>
              <button
                type="button"
                class="button button--outline"
                phx-hook="CopyToClipboard"
                id="copy-tiktok-oauth-url"
                data-copy-text={@tiktok_oauth_url}
              >
                Copy Link
              </button>
              <span :if={is_nil(@tiktok_auth)} class="settings-actions__hint">
                Send the link to the TikTok Shop owner to authorize.
              </span>
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

  @doc """
  Modal for creating a new brand.
  """
  attr :form, :any, required: true
  attr :on_cancel, :any, required: true

  def new_brand_modal(assigns) do
    ~H"""
    <.modal id="new-brand-modal" show={true} on_cancel={@on_cancel}>
      <div class="modal__header">
        <h2 class="modal__title">New Brand</h2>
      </div>
      <div class="modal__body">
        <.form
          for={@form}
          id="new-brand-form"
          phx-change="validate_new_brand"
          phx-submit="create_brand"
        >
          <div class="settings-grid">
            <div class="settings-field">
              <.input
                field={@form[:name]}
                type="text"
                label="Brand Name"
                placeholder="My Brand"
                phx-debounce="300"
              />
            </div>
            <div class="settings-field">
              <.input
                field={@form[:slug]}
                type="text"
                label="Slug"
                placeholder="my-brand"
                phx-debounce="300"
              />
              <p class="settings-hint">
                URL-friendly identifier. Auto-generated from name if left blank.
              </p>
            </div>
          </div>
        </.form>
      </div>
      <div class="modal__footer">
        <.button variant="outline" phx-click={@on_cancel}>Cancel</.button>
        <.button
          variant="primary"
          form="new-brand-form"
          type="submit"
          phx-disable-with="Creating..."
        >
          Create Brand
        </.button>
      </div>
    </.modal>
    """
  end

  @doc """
  Modal for creating a new user with temporary password.
  """
  attr :form, :any, required: true
  attr :brands, :list, default: []
  attr :on_cancel, :any, required: true

  def new_user_modal(assigns) do
    ~H"""
    <.modal id="new-user-modal" show={true} on_cancel={@on_cancel}>
      <div class="modal__header">
        <h2 class="modal__title">Add User</h2>
      </div>
      <div class="modal__body">
        <.form for={@form} id="new-user-form" phx-submit="create_user">
          <div class="settings-grid">
            <div class="settings-field settings-field--full">
              <.input
                field={@form[:email]}
                type="email"
                label="Email"
                placeholder="user@example.com"
                required
              />
            </div>
            <div class="settings-field settings-field--full">
              <label class="checkbox-label">
                <input type="checkbox" name="is_admin" value="true" class="checkbox" />
                <span>Make platform admin</span>
              </label>
            </div>
          </div>
          <div :if={@brands != []} class="settings-subsection" style="margin-top: var(--space-4);">
            <h3 class="settings-subsection__title">Brand Access</h3>
            <p class="settings-subsection__description">
              Select which brands this user can access and their role for each.
            </p>
            <div class="brand-access-list">
              <div :for={brand <- @brands} class="brand-access-row">
                <label class="checkbox-label">
                  <input
                    type="checkbox"
                    name={"brands[#{brand.id}][enabled]"}
                    value="true"
                    class="checkbox"
                  />
                  <span>{brand.name}</span>
                </label>
                <select name={"brands[#{brand.id}][role]"} class="input input--sm">
                  <option value="viewer">Viewer</option>
                  <option value="admin">Admin</option>
                  <option value="owner">Owner</option>
                </select>
              </div>
            </div>
          </div>
        </.form>
      </div>
      <div class="modal__footer">
        <.button variant="outline" phx-click={@on_cancel}>Cancel</.button>
        <.button
          variant="primary"
          form="new-user-form"
          type="submit"
          phx-disable-with="Creating..."
        >
          Create User
        </.button>
      </div>
    </.modal>
    """
  end

  @doc """
  Modal showing the generated temporary password after user creation.
  """
  attr :email, :string, required: true
  attr :temp_password, :string, required: true
  attr :on_close, :any, required: true

  def user_created_modal(assigns) do
    ~H"""
    <.modal id="user-created-modal" show={true} on_cancel={@on_close}>
      <div class="modal__header">
        <h2 class="modal__title">User Created</h2>
      </div>
      <div class="modal__body">
        <p style="margin-bottom: var(--space-4);">
          Account created for <strong>{@email}</strong>
        </p>
        <div class="settings-field">
          <label class="input-label">Temporary Password</label>
          <div class="temp-password-display">
            <code class="temp-password-code">{@temp_password}</code>
            <button
              type="button"
              class="button button--sm button--outline"
              phx-hook="CopyToClipboard"
              id="copy-temp-password"
              data-copy-text={@temp_password}
            >
              Copy
            </button>
          </div>
        </div>
        <p class="settings-hint" style="margin-top: var(--space-4);">
          Share these credentials with the user. They will be required to set a new password on first login.
        </p>
      </div>
      <div class="modal__footer">
        <.button variant="primary" phx-click={@on_close}>Done</.button>
      </div>
    </.modal>
    """
  end

  # ===========================================================================
  # Monitoring Dashboard Components
  # ===========================================================================

  @doc """
  Renders the queue health stats as compact cards.
  """
  attr :stats, :map, required: true

  def queue_health_stats(assigns) do
    ~H"""
    <div class="queue-stats">
      <div class="queue-stat-card">
        <div class="queue-stat-card__value">{@stats.pending}</div>
        <div class="queue-stat-card__label">Pending</div>
      </div>
      <div class="queue-stat-card queue-stat-card--running">
        <div class="queue-stat-card__value">{@stats.running}</div>
        <div class="queue-stat-card__label">Running</div>
      </div>
      <div class="queue-stat-card">
        <div class="queue-stat-card__value">{length(Map.keys(@stats.by_queue))}</div>
        <div class="queue-stat-card__label">Queues</div>
      </div>
      <div class="queue-stat-card queue-stat-card--failed">
        <div class="queue-stat-card__value">{@stats.failed}</div>
        <div class="queue-stat-card__label">Failed</div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a worker category panel with its workers.
  """
  attr :category, :atom, required: true
  attr :label, :string, required: true
  attr :workers, :list, required: true
  attr :statuses, :map, required: true
  attr :running_workers, :list, required: true
  attr :rate_limit_info, :map, default: nil
  attr :brand_id, :any, required: true

  def worker_category_panel(assigns) do
    ~H"""
    <div class="worker-category">
      <div class="worker-category__header">
        <h3 class="worker-category__title">{@label}</h3>
      </div>
      <table class="worker-table">
        <thead>
          <tr>
            <th>Worker</th>
            <th>Schedule</th>
            <th>Last Run</th>
            <th>Status</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <.worker_row
            :for={worker <- @workers}
            worker={worker}
            status={get_worker_status(@statuses, @brand_id, worker.status_key)}
            worker_state={get_worker_state(@running_workers, worker.key)}
            rate_limit_info={if worker.key == :creator_enrichment, do: @rate_limit_info, else: nil}
            brand_id={@brand_id}
          />
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders a single worker row in the monitoring table.
  """
  attr :worker, :map, required: true
  attr :status, :any, default: nil
  attr :worker_state, :atom, default: nil
  attr :rate_limit_info, :map, default: nil
  attr :brand_id, :any, required: true

  def worker_row(assigns) do
    ~H"""
    <tr>
      <td>
        <div class="worker-name">{@worker.name}</div>
        <div class="worker-description">{@worker.description}</div>
        <.rate_limit_warning
          :if={@rate_limit_info && @rate_limit_info.streak > 0}
          info={@rate_limit_info}
        />
      </td>
      <td>
        <span class="worker-schedule">{@worker.schedule}</span>
      </td>
      <td>
        <span class="worker-status__text">{format_last_run(@status)}</span>
      </td>
      <td>
        <div class="worker-status">
          <span class={"worker-status__indicator " <> status_indicator_class(@status, @worker_state)} />
          <span class={"worker-status__text " <> if(@worker_state == :running, do: "worker-status__text--running", else: "")}>
            {status_text(@status, @worker_state)}
          </span>
        </div>
      </td>
      <td>
        <.button
          :if={@worker.triggerable}
          size="sm"
          variant="primary"
          phx-click="trigger_worker"
          phx-value-worker={@worker.key}
          phx-value-brand_id={@brand_id}
          disabled={@worker_state != nil}
        >
          {button_label(@worker_state)}
        </.button>
      </td>
    </tr>
    """
  end

  @doc """
  Renders a rate limit warning message.
  """
  attr :info, :map, required: true

  def rate_limit_warning(assigns) do
    ~H"""
    <div class="worker-rate-limit">
      <span class="worker-rate-limit__icon">⚠</span>
      <span>
        Rate limited {format_relative_time(@info.last_limited_at)}
        {if @info.streak > 1, do: "(streak: #{@info.streak})", else: ""}
      </span>
    </div>
    """
  end

  @doc """
  Renders the failed jobs table.
  """
  attr :jobs, :list, required: true

  def failed_jobs_table(assigns) do
    ~H"""
    <div :if={@jobs != []} class="failed-jobs-panel">
      <div class="failed-jobs-panel__header">
        <h3 class="failed-jobs-panel__title">Recent Failed Jobs</h3>
      </div>
      <table class="failed-jobs-table">
        <thead>
          <tr>
            <th>Worker</th>
            <th>Error</th>
            <th>When</th>
            <th>State</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={job <- @jobs}>
            <td>
              <span class="worker-name">{job.worker_name}</span>
            </td>
            <td>
              <span class="failed-job__error" title={job.error}>{job.error}</span>
            </td>
            <td>
              <span class="failed-job__when">{format_relative_time(job.attempted_at)}</span>
            </td>
            <td>
              <span class={"failed-job__state failed-job__state--#{job.state}"}>{job.state}</span>
            </td>
            <td>
              <.button
                :if={job.state == "retryable"}
                size="sm"
                variant="primary"
                phx-click="retry_job"
                phx-value-job_id={job.id}
              >
                Retry
              </.button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # Helper functions
  defp format_datetime(nil), do: "-"
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %d, %Y %H:%M")
  defp format_datetime(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%b %d, %Y %H:%M")

  def secret_configured?(secrets_configured, key), do: MapSet.member?(secrets_configured, key)
  def secret_visible?(visible_secrets, key), do: MapSet.member?(visible_secrets, key)

  # Monitoring helper functions

  defp get_worker_status(_statuses, _brand_id, nil), do: nil

  defp get_worker_status(statuses, brand_id, status_key) do
    Map.get(statuses, {brand_id, status_key})
  end

  defp get_worker_state(running_workers, worker_key) do
    case Enum.find(running_workers, fn rw -> rw.worker_key == worker_key end) do
      nil -> nil
      worker -> worker.state
    end
  end

  defp button_label(:running), do: "Running..."
  defp button_label(:pending), do: "Pending..."
  defp button_label(_), do: "Run"

  defp format_last_run(nil), do: "Never"
  defp format_last_run(datetime), do: format_relative_time(datetime)

  defp status_indicator_class(_status, :running), do: "worker-status__indicator--running"
  defp status_indicator_class(_status, :pending), do: "worker-status__indicator--running"
  defp status_indicator_class(nil, _), do: "worker-status__indicator--stale"

  defp status_indicator_class(datetime, _) do
    hours_ago = DateTime.diff(DateTime.utc_now(), datetime, :hour)

    cond do
      hours_ago < 24 -> "worker-status__indicator--ok"
      hours_ago < 72 -> "worker-status__indicator--warning"
      true -> "worker-status__indicator--stale"
    end
  end

  defp status_text(_status, :running), do: "Running"
  defp status_text(_status, :pending), do: "Pending"
  defp status_text(nil, _), do: "Never run"

  defp status_text(datetime, _) do
    hours_ago = DateTime.diff(DateTime.utc_now(), datetime, :hour)

    cond do
      hours_ago < 24 -> "OK"
      hours_ago < 72 -> "Stale"
      true -> "Stale"
    end
  end
end
