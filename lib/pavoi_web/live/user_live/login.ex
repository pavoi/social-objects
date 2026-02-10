defmodule PavoiWeb.UserLive.Login do
  use PavoiWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <div class="auth-page">
      <Layouts.flash_group flash={@flash} />

      <div class="auth-card">
        <div class="auth-header">
          <h1 class="auth-title">Log in</h1>
          <p class="auth-subtitle">
            Enter your email and password to sign in.
          </p>
        </div>

        <.form
          for={@form}
          id="login_form"
          action={~p"/users/log-in"}
          phx-update="ignore"
          class="auth-form"
        >
          <.input
            field={@form[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="current-password"
            required
          />
          <label class="form-checkbox">
            <input type="checkbox" name="user[remember_me]" value="true" checked />
            <span class="form-checkbox__label">Keep me logged in</span>
          </label>
          <.button variant="primary" phx-disable-with="Logging in...">
            Log in <span aria-hidden="true">→</span>
          </.button>
        </.form>

        <p class="auth-footer">
          Need access? Contact your admin for an invite.
        </p>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email = Phoenix.Flash.get(socket.assigns.flash, :email)
    form = to_form(%{"email" => email}, as: "user")

    {:ok, assign(socket, form: form), temporary_assigns: [form: form]}
  end
end
