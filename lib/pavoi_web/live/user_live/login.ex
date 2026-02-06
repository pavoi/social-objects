defmodule PavoiWeb.UserLive.Login do
  use PavoiWeb, :live_view

  alias Pavoi.Accounts
  alias Pavoi.Accounts.Scope

  @impl true
  def render(assigns) do
    ~H"""
    <div class="auth-page">
      <Layouts.flash_group flash={@flash} />

      <div class="auth-card">
        <div class="auth-header">
          <h1 class="auth-title">Log in</h1>
          <p class="auth-subtitle">
            <%= if @current_scope do %>
              You need to reauthenticate to perform sensitive actions on your account.
            <% else %>
              Enter your email address and we'll send you a magic link to sign in.
            <% end %>
          </p>
        </div>

        <div :if={local_mail_adapter?()} class="auth-info">
          <svg
            class="size-5"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <circle cx="12" cy="12" r="10" /><line x1="12" y1="16" x2="12" y2="12" /><line
              x1="12"
              y1="8"
              x2="12.01"
              y2="8"
            />
          </svg>
          <div class="auth-info__content">
            <p>You are running the local mail adapter.</p>
            <p>
              To see sent emails, visit <.link href="/dev/mailbox">the mailbox page</.link>.
            </p>
          </div>
        </div>

        <.form
          for={@form}
          id="login_form_magic"
          action={~p"/users/log-in"}
          phx-submit="submit_magic"
          class="auth-form"
        >
          <.input
            readonly={!!@current_scope}
            field={@form[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            required
            phx-mounted={JS.focus()}
          />
          <.button variant="primary" phx-disable-with="Sending link...">
            Send magic link <span aria-hidden="true">→</span>
          </.button>
        </.form>

        <p :if={!@current_scope} class="auth-footer">
          Need access? Contact your admin for an invite.
        </p>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        case socket.assigns.current_scope do
          %Scope{user: %Accounts.User{email: email}} -> email
          _ -> nil
        end

    form = to_form(%{"email" => email}, as: "user")

    {:ok, assign(socket, form: form)}
  end

  @impl true
  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )
    end

    info =
      "If your email is in our system, you will receive instructions for logging in shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  defp local_mail_adapter? do
    Application.get_env(:pavoi, Pavoi.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
