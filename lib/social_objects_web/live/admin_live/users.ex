defmodule SocialObjectsWeb.AdminLive.Users do
  @moduledoc """
  Admin page for listing and managing all users.
  Includes user detail modal for viewing/editing individual users.
  """
  use SocialObjectsWeb, :live_view

  import SocialObjectsWeb.AdminComponents

  alias Phoenix.LiveView.JS
  alias SocialObjects.Accounts
  alias SocialObjects.Catalog

  @impl true
  def mount(_params, _session, socket) do
    users = Accounts.list_all_users()
    brands = Catalog.list_brands()

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
     |> assign(:brands, brands)
     |> assign(:selected_user, nil)
     |> assign(:selected_user_last_session, nil)
     |> assign(:show_new_user_modal, false)
     |> assign(:new_user_form, to_form(%{"email" => ""}))
     |> assign(:created_user_email, nil)
     |> assign(:created_user_temp_password, nil)
     # New assigns for enhanced features
     |> assign(:show_add_brand_form, false)
     |> assign(:available_brands, [])
     |> assign(:reset_password_result, nil)
     |> assign(:current_user_id, socket.assigns.current_scope.user.id)}
  end

  @impl true
  def handle_event("view_user", %{"user_id" => user_id}, socket) do
    user = Accounts.get_user_with_brands!(user_id)
    last_session = Accounts.get_last_session_at(user)
    available_brands = get_available_brands(socket.assigns.brands, user)

    {:noreply,
     socket
     |> assign(:selected_user, user)
     |> assign(:selected_user_last_session, last_session)
     |> assign(:available_brands, available_brands)
     |> assign(:show_add_brand_form, false)
     |> assign(:reset_password_result, nil)}
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_user, nil)
     |> assign(:selected_user_last_session, nil)
     |> assign(:show_new_user_modal, false)
     |> assign(:created_user_email, nil)
     |> assign(:created_user_temp_password, nil)
     |> assign(:show_add_brand_form, false)
     |> assign(:available_brands, [])
     |> assign(:reset_password_result, nil)}
  end

  @impl true
  def handle_event("show_new_user_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_new_user_modal, true)
     |> assign(:new_user_form, to_form(%{"email" => ""}))}
  end

  @impl true
  def handle_event("create_user", params, socket) do
    email = String.trim(params["email"] || "")
    is_admin = params["is_admin"] == "true"
    brand_assignments = parse_brand_assignments(params["brands"] || %{})

    case Accounts.create_user_with_temp_password(email) do
      {:ok, user, temp_password} ->
        # Set admin status if requested
        _ =
          if is_admin do
            Accounts.set_admin_status(user, true)
          end

        # Assign to selected brands
        _ =
          for {brand_id, role} <- brand_assignments do
            brand = Catalog.get_brand!(brand_id)
            _ = Accounts.create_user_brand(user, brand, role)
          end

        # Reload users list
        users = reload_users()

        {:noreply,
         socket
         |> assign(:users, users)
         |> assign(:show_new_user_modal, false)
         |> assign(:new_user_form, to_form(%{"email" => ""}))
         |> assign(:created_user_email, email)
         |> assign(:created_user_temp_password, temp_password)}

      {:error, changeset} ->
        error_msg = format_changeset_errors(changeset)

        {:noreply, put_flash(socket, :error, "Failed to create user: #{error_msg}")}
    end
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
        available_brands = get_available_brands(socket.assigns.brands, updated_user)

        # Update users list
        users = update_user_in_list(socket.assigns.users, updated_user, last_session)

        {:noreply,
         socket
         |> assign(:users, users)
         |> assign(:selected_user, updated_user)
         |> assign(:available_brands, available_brands)
         |> put_flash(:info, "User removed from #{brand.name}.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to remove user from brand.")}
    end
  end

  # Change brand role inline
  @impl true
  def handle_event(
        "change_brand_role",
        %{"user_id" => user_id, "brand_id" => brand_id, "role" => role},
        socket
      ) do
    user = Accounts.get_user_with_brands!(user_id)
    brand = Catalog.get_brand!(brand_id)
    new_role = String.to_existing_atom(role)

    case Accounts.update_user_brand_role(user, brand, new_role) do
      :ok ->
        updated_user = Accounts.get_user_with_brands!(user.id)
        last_session = Accounts.get_last_session_at(updated_user)
        users = update_user_in_list(socket.assigns.users, updated_user, last_session)

        {:noreply,
         socket
         |> assign(:users, users)
         |> assign(:selected_user, updated_user)
         |> put_flash(:info, "Role updated to #{role}.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update role.")}
    end
  end

  # Add brand form toggle
  @impl true
  def handle_event("show_add_brand_form", _params, socket) do
    {:noreply, assign(socket, :show_add_brand_form, true)}
  end

  @impl true
  def handle_event("cancel_add_brand", _params, socket) do
    {:noreply, assign(socket, :show_add_brand_form, false)}
  end

  # Add brand membership
  @impl true
  def handle_event("add_brand_membership", %{"brand_id" => brand_id, "role" => role}, socket) do
    user = socket.assigns.selected_user
    brand = Catalog.get_brand!(brand_id)
    role_atom = String.to_existing_atom(role)

    case Accounts.create_user_brand(user, brand, role_atom) do
      {:ok, _} ->
        updated_user = Accounts.get_user_with_brands!(user.id)
        last_session = Accounts.get_last_session_at(updated_user)
        available_brands = get_available_brands(socket.assigns.brands, updated_user)
        users = update_user_in_list(socket.assigns.users, updated_user, last_session)

        {:noreply,
         socket
         |> assign(:users, users)
         |> assign(:selected_user, updated_user)
         |> assign(:available_brands, available_brands)
         |> assign(:show_add_brand_form, false)
         |> put_flash(:info, "Added to #{brand.name} as #{role}.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to add brand membership.")}
    end
  end

  # Reset password
  @impl true
  def handle_event("reset_password", %{"user_id" => user_id}, socket) do
    user = Accounts.get_user!(user_id)

    case Accounts.reset_user_password(user) do
      {:ok, _user, temp_password} ->
        {:noreply,
         socket
         |> assign(:reset_password_result, %{email: user.email, temp_password: temp_password})}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to reset password.")}
    end
  end

  @impl true
  def handle_event("close_reset_modal", _params, socket) do
    {:noreply, assign(socket, :reset_password_result, nil)}
  end

  # Delete user
  @impl true
  def handle_event("delete_user", _params, socket) do
    user = socket.assigns.selected_user

    cond do
      user.id == socket.assigns.current_user_id ->
        {:noreply, put_flash(socket, :error, "You cannot delete yourself.")}

      Accounts.only_admin?(user) ->
        {:noreply, put_flash(socket, :error, "Cannot delete the only platform admin.")}

      true ->
        case Accounts.delete_user(user) do
          {:ok, _} ->
            users = reload_users()

            {:noreply,
             socket
             |> assign(:users, users)
             |> assign(:selected_user, nil)
             |> put_flash(:info, "User #{user.email} deleted.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete user.")}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="admin-page">
      <div class="admin-page__header">
        <h1 class="admin-page__title">Users</h1>
        <.button phx-click="show_new_user_modal" variant="primary">
          Add User
        </.button>
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
        :if={@selected_user && !@reset_password_result}
        user={@selected_user}
        last_session_at={@selected_user_last_session}
        current_user_id={@current_user_id}
        show_add_brand_form={@show_add_brand_form}
        available_brands={@available_brands}
        on_cancel={JS.push("close_modal")}
      />

      <.password_reset_result_modal
        :if={@reset_password_result}
        email={@reset_password_result.email}
        temp_password={@reset_password_result.temp_password}
        on_close={JS.push("close_reset_modal")}
      />

      <.new_user_modal
        :if={@show_new_user_modal}
        form={@new_user_form}
        brands={@brands}
        on_cancel={JS.push("close_modal")}
      />

      <.user_created_modal
        :if={@created_user_temp_password}
        email={@created_user_email}
        temp_password={@created_user_temp_password}
        on_close={JS.push("close_modal")}
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

  defp reload_users do
    Accounts.list_all_users()
    |> Enum.map(fn user ->
      last_session = Accounts.get_last_session_at(user)
      Map.put(user, :last_session_at, last_session)
    end)
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join(", ", fn {field, errors} -> "#{field} #{Enum.join(errors, ", ")}" end)
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

  defp parse_brand_assignments(brands_params) when is_map(brands_params) do
    brands_params
    |> Enum.filter(fn {_brand_id, params} -> params["enabled"] == "true" end)
    |> Enum.map(fn {brand_id, params} ->
      role = String.to_existing_atom(params["role"] || "viewer")
      {brand_id, role}
    end)
  end

  defp parse_brand_assignments(_), do: []

  defp get_available_brands(all_brands, user) do
    user_brand_ids = Enum.map(user.user_brands, & &1.brand.id)
    Enum.reject(all_brands, fn brand -> brand.id in user_brand_ids end)
  end
end
