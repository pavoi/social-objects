defmodule PavoiWeb.AdminLive.Users do
  @moduledoc """
  Admin page for listing and managing all users.
  Includes user detail modal for viewing/editing individual users.
  """
  use PavoiWeb, :live_view

  import PavoiWeb.AdminComponents

  alias Pavoi.Accounts
  alias Pavoi.Catalog
  alias Phoenix.LiveView.JS

  @impl true
  def mount(_params, _session, socket) do
    users = Accounts.list_all_users()

    # Fetch last session timestamps for all users
    users_with_sessions =
      Enum.map(users, fn user ->
        last_session = Accounts.get_last_session_at(user)
        Map.put(user, :last_session_at, last_session)
      end)

    {:ok,
     socket
     |> assign(:page_title, "Users")
     |> assign(:users, users_with_sessions)
     |> assign(:selected_user, nil)
     |> assign(:selected_user_last_session, nil)}
  end

  @impl true
  def handle_event("view_user", %{"user_id" => user_id}, socket) do
    user = Accounts.get_user_with_brands!(user_id)
    last_session = Accounts.get_last_session_at(user)

    {:noreply,
     socket
     |> assign(:selected_user, user)
     |> assign(:selected_user_last_session, last_session)}
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_user, nil)
     |> assign(:selected_user_last_session, nil)}
  end

  @impl true
  def handle_event("toggle_admin", %{"user_id" => user_id}, socket) do
    user = Accounts.get_user_with_brands!(user_id)
    new_status = !user.is_admin

    case Accounts.set_admin_status(user, new_status) do
      {:ok, updated_user} ->
        # Reload with brands
        updated_user = Accounts.get_user_with_brands!(updated_user.id)
        last_session = Accounts.get_last_session_at(updated_user)

        # Update users list
        users = update_user_in_list(socket.assigns.users, updated_user, last_session)

        {:noreply,
         socket
         |> assign(:users, users)
         |> assign(:selected_user, updated_user)
         |> put_flash(:info, "Admin status updated.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update admin status.")}
    end
  end

  @impl true
  def handle_event("remove_from_brand", %{"user_id" => user_id, "brand_id" => brand_id}, socket) do
    user = Accounts.get_user_with_brands!(user_id)
    brand = Catalog.get_brand!(brand_id)

    case Accounts.remove_user_from_brand(user, brand) do
      {1, _} ->
        updated_user = Accounts.get_user_with_brands!(user.id)
        last_session = Accounts.get_last_session_at(updated_user)

        # Update users list
        users = update_user_in_list(socket.assigns.users, updated_user, last_session)

        {:noreply,
         socket
         |> assign(:users, users)
         |> assign(:selected_user, updated_user)
         |> put_flash(:info, "User removed from #{brand.name}.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to remove user from brand.")}
    end
  end

  defp update_user_in_list(users, updated_user, last_session) do
    Enum.map(users, fn user ->
      if user.id == updated_user.id do
        updated_user
        |> Map.put(:last_session_at, last_session)
      else
        user
      end
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="admin-page">
      <div class="admin-page__header">
        <h1 class="admin-page__title">Users</h1>
      </div>

      <div class="admin-panel">
        <div class="admin-panel__body--flush">
          <.admin_table id="users-table" rows={@users} row_id={fn user -> "user-#{user.id}" end}>
            <:col :let={user} label="Email">
              {user.email}
            </:col>
            <:col :let={user} label="Admin">
              <.badge :if={user.is_admin} variant={:primary}>Admin</.badge>
              <span :if={!user.is_admin} class="text-secondary">-</span>
            </:col>
            <:col :let={user} label="Brands">
              {format_user_brands(user.user_brands)}
            </:col>
            <:col :let={user} label="Last Session">
              {format_datetime(user.last_session_at)}
            </:col>
            <:col :let={user} label="Created">
              {format_datetime(user.inserted_at)}
            </:col>
            <:action :let={user}>
              <.button phx-click="view_user" phx-value-user_id={user.id} size="sm" variant="outline">
                View
              </.button>
            </:action>
          </.admin_table>
        </div>
      </div>

      <.user_detail_modal
        :if={@selected_user}
        user={@selected_user}
        last_session_at={@selected_user_last_session}
        on_cancel={JS.push("close_modal")}
      />
    </div>
    """
  end

  defp format_user_brands(user_brands) when is_list(user_brands) do
    Enum.map_join(user_brands, ", ", fn ub -> "#{ub.brand.name} (#{ub.role})" end)
  end

  defp format_user_brands(_), do: "-"

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %Y %H:%M")
  end

  defp format_datetime(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %Y %H:%M")
  end
end
