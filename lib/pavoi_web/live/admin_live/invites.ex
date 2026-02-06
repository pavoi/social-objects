defmodule PavoiWeb.AdminLive.Invites do
  @moduledoc """
  Admin page for managing brand invites.
  """
  use PavoiWeb, :live_view

  import PavoiWeb.AdminComponents

  alias Pavoi.Accounts
  alias Pavoi.Catalog
  alias PavoiWeb.BrandRoutes

  @impl true
  def mount(_params, _session, socket) do
    brands = Catalog.list_brands()
    pending_invites = Accounts.list_all_pending_invites()

    {:ok,
     socket
     |> assign(:page_title, "Invites")
     |> assign(:brands, brands)
     |> assign(:pending_invites, pending_invites)
     |> assign(:form, to_form(%{"email" => "", "brand_id" => "", "role" => "viewer"}))}
  end

  @impl true
  def handle_event(
        "send_invite",
        %{"email" => email, "brand_id" => brand_id, "role" => role},
        socket
      ) do
    email = String.trim(email)
    current_user = socket.assigns.current_scope.user

    if email == "" || brand_id == "" do
      {:noreply, put_flash(socket, :error, "Email and brand are required.")}
    else
      brand = Catalog.get_brand!(brand_id)
      do_send_invite(socket, brand, email, role, current_user)
    end
  end

  def handle_event("resend_invite", %{"invite_id" => invite_id}, socket) do
    invite = Pavoi.Repo.get!(Accounts.BrandInvite, invite_id) |> Pavoi.Repo.preload(:brand)
    brand = invite.brand

    invite_url_fn = fn token ->
      BrandRoutes.brand_invite_url(brand, token)
    end

    Accounts.deliver_brand_invite(invite, brand, invite_url_fn)

    {:noreply, put_flash(socket, :info, "Invite resent to #{invite.email}.")}
  end

  defp do_send_invite(socket, brand, email, role, current_user) do
    case Accounts.create_brand_invite(brand, email, role, current_user) do
      {:ok, invite} ->
        invite_url_fn = &BrandRoutes.brand_invite_url(brand, &1)
        Accounts.deliver_brand_invite(invite, brand, invite_url_fn)
        pending_invites = Accounts.list_all_pending_invites()

        {:noreply,
         socket
         |> assign(:pending_invites, pending_invites)
         |> assign(:form, to_form(%{"email" => "", "brand_id" => "", "role" => "viewer"}))
         |> put_flash(:info, "Invite sent to #{email}.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create invite.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="admin-page">
      <div class="admin-page__header">
        <h1 class="admin-page__title">Invites</h1>
      </div>

      <div class="admin-body">
        <div class="admin-panel">
          <div class="admin-panel__header">
            <h2 class="admin-panel__title">Send New Invite</h2>
          </div>
          <div class="admin-panel__body">
            <form phx-submit="send_invite" class="admin-form">
              <div class="admin-form__row">
                <div class="input-group">
                  <label class="input-label" for="invite-email">Email</label>
                  <input
                    type="email"
                    id="invite-email"
                    name="email"
                    value={@form.params["email"]}
                    class="input"
                    placeholder="user@example.com"
                    required
                  />
                </div>
                <div class="input-group">
                  <label class="input-label" for="invite-brand">Brand</label>
                  <select id="invite-brand" name="brand_id" class="input" required>
                    <option value="">Select brand...</option>
                    <option :for={brand <- @brands} value={brand.id}>{brand.name}</option>
                  </select>
                </div>
                <div class="input-group">
                  <label class="input-label" for="invite-role">Role</label>
                  <select id="invite-role" name="role" class="input">
                    <option value="viewer">Viewer</option>
                    <option value="admin">Admin</option>
                    <option value="owner">Owner</option>
                  </select>
                </div>
              </div>
              <div class="admin-form__actions">
                <.button type="submit" variant="primary">
                  Send Invite
                </.button>
              </div>
            </form>
          </div>
        </div>

        <div class="admin-panel">
          <div class="admin-panel__header">
            <h2 class="admin-panel__title">Pending Invites ({length(@pending_invites)})</h2>
          </div>
          <div class="admin-panel__body--flush">
            <.admin_table
              id="invites-table"
              rows={@pending_invites}
              row_id={fn invite -> "invite-#{invite.id}" end}
            >
              <:col :let={invite} label="Email">
                {invite.email}
              </:col>
              <:col :let={invite} label="Brand">
                {invite.brand.name}
              </:col>
              <:col :let={invite} label="Role">
                <.badge variant={role_variant(invite.role)}>{invite.role}</.badge>
              </:col>
              <:col :let={invite} label="Expires">
                {format_datetime(invite.expires_at)}
              </:col>
              <:action :let={invite}>
                <.button
                  phx-click="resend_invite"
                  phx-value-invite_id={invite.id}
                  size="sm"
                  variant="outline"
                >
                  Resend
                </.button>
              </:action>
            </.admin_table>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %Y %H:%M")
  end

  defp role_variant("owner"), do: :primary
  defp role_variant("admin"), do: :success
  defp role_variant(_), do: :default
end
