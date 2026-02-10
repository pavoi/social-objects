defmodule PavoiWeb.UserLive.ChangePassword do
  use PavoiWeb, :live_view

  alias Pavoi.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <div class="auth-page">
      <Layouts.flash_group flash={@flash} />

      <div class="auth-card">
        <div class="auth-header">
          <h1 class="auth-title">Change Password</h1>
          <p class="auth-subtitle">
            Please set a new password to continue using the application.
          </p>
        </div>

        <.form
          for={@form}
          id="password_form"
          phx-change="validate"
          phx-submit="save"
          class="auth-form"
        >
          <.input
            field={@form[:password]}
            type="password"
            label="New password"
            autocomplete="new-password"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={@form[:password_confirmation]}
            type="password"
            label="Confirm new password"
            autocomplete="new-password"
            required
          />
          <.button variant="primary" phx-disable-with="Saving...">
            Change Password
          </.button>
        </.form>

        <p class="auth-footer">
          Password must be 12-72 characters.
        </p>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    # Redirect away if user doesn't need to change password
    if user.must_change_password do
      changeset = Accounts.change_user_password(user, %{}, hash_password: false)
      {:ok, assign(socket, form: to_form(changeset))}
    else
      {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"user" => user_params}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.update_user_password(user, user_params) do
      {:ok, {_user, _tokens}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Password changed successfully.")
         |> push_navigate(to: ~p"/")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
