defmodule PavoiWeb.AdminLive.Dashboard do
  @moduledoc """
  Admin dashboard with overview stats and quick actions.
  """
  use PavoiWeb, :live_view

  import PavoiWeb.AdminComponents

  alias Pavoi.Accounts
  alias Pavoi.Catalog

  @impl true
  def mount(_params, _session, socket) do
    brands = Catalog.list_brands()
    users = Accounts.list_all_users()
    pending_invites = Accounts.list_all_pending_invites()

    {:ok,
     socket
     |> assign(:page_title, "Admin Dashboard")
     |> assign(:brand_count, length(brands))
     |> assign(:user_count, length(users))
     |> assign(:invite_count, length(pending_invites))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="admin-page">
      <div class="admin-page__header">
        <h1 class="admin-page__title">Dashboard</h1>
      </div>

      <div class="admin-body">
        <div class="stat-cards">
          <.stat_card label="Brands" value={@brand_count} href={~p"/admin/brands"} />
          <.stat_card label="Users" value={@user_count} href={~p"/admin/users"} />
          <.stat_card label="Pending Invites" value={@invite_count} href={~p"/admin/invites"} />
        </div>

        <div class="admin-panel">
          <div class="admin-panel__header">
            <h2 class="admin-panel__title">Quick Actions</h2>
          </div>
          <div class="admin-panel__body">
            <div class="quick-actions">
              <.button navigate={~p"/admin/invites"} variant="primary">
                Send Invite
              </.button>
              <.button navigate={~p"/admin/brands"} variant="outline">
                Manage Brands
              </.button>
              <.button navigate={~p"/admin/users"} variant="outline">
                Manage Users
              </.button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
