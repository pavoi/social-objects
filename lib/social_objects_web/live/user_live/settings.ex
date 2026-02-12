defmodule SocialObjectsWeb.UserLive.Settings do
  use SocialObjectsWeb, :live_view

  on_mount {SocialObjectsWeb.UserAuth, :require_authenticated}

  alias SocialObjects.Accounts
  alias SocialObjects.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-full max-w-screen-sm px-4 region">
      <div class="settings-page">
        <section class="settings-section">
          <div class="settings-section__header">
            <h2 class="settings-section__title">Appearance</h2>
          </div>

          <div class="settings-theme-row">
            <span class="settings-theme-row__label">Theme</span>
            <.theme_switch />
          </div>
        </section>

        <section class="settings-section">
          <div class="settings-section__header">
            <h2 class="settings-section__title">Email Address</h2>
            <p class="settings-section__description">
              Update your email address.
            </p>
          </div>

          <.form
            for={@email_form}
            id="email_form"
            phx-submit="update_email"
            phx-change="validate_email"
          >
            <.input
              field={@email_form[:email]}
              type="email"
              label="New email"
              autocomplete="username"
              required
            />
            <.input
              field={@email_form[:current_password]}
              id="email_form_current_password"
              type="password"
              label="Current password"
              autocomplete="current-password"
              required
            />
            <div>
              <.button variant="primary" phx-disable-with="Changing...">
                Change Email
              </.button>
            </div>
          </.form>
        </section>

        <section class="settings-section">
          <div class="settings-section__header">
            <h2 class="settings-section__title">Password</h2>
            <p class="settings-section__description">
              Update your password. You will be logged out of all other sessions.
            </p>
          </div>

          <.form
            for={@password_form}
            id="password_form"
            phx-submit="update_password"
            phx-change="validate_password"
          >
            <.input
              field={@password_form[:current_password]}
              id="password_form_current_password"
              type="password"
              label="Current password"
              autocomplete="current-password"
              required
            />
            <.input
              field={@password_form[:password]}
              type="password"
              label="New password"
              autocomplete="new-password"
              required
            />
            <.input
              field={@password_form[:password_confirmation]}
              type="password"
              label="Confirm new password"
              autocomplete="new-password"
              required
            />
            <div>
              <.button variant="primary" phx-disable-with="Changing...">
                Change Password
              </.button>
            </div>
          </.form>
        </section>

        <section class="settings-section">
          <.button href={~p"/users/log-out"} method="delete" variant="outline">
            Log out
          </.button>
        </section>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    # Get user's brands for the navbar
    user_brands = Accounts.list_user_brands(user)
    # Use the first brand as the current brand for navbar context
    first_brand =
      case user_brands do
        [ub | _] -> ub.brand
        [] -> nil
      end

    socket =
      socket
      |> assign(:current_brand, first_brand)
      |> assign(:user_brands, user_brands)
      |> assign(:current_host, nil)
      |> assign(:current_page, :account_settings)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    current_password = user_params["current_password"]

    if User.valid_password?(user, current_password) do
      case Accounts.update_user_email(user, user_params) do
        {:ok, updated_user} ->
          email_changeset = Accounts.change_user_email(updated_user, %{}, validate_unique: false)

          {:noreply,
           socket
           |> put_flash(:info, "Email changed successfully.")
           |> assign(:email_form, to_form(email_changeset))}

        {:error, changeset} ->
          {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
      end
    else
      changeset =
        Accounts.change_user_email(user, user_params, validate_unique: false)
        |> Ecto.Changeset.add_error(:current_password, "is incorrect")

      {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    current_password = user_params["current_password"]

    if User.valid_password?(user, current_password) do
      case Accounts.update_user_password(user, user_params) do
        {:ok, {_user, tokens}} ->
          SocialObjectsWeb.UserAuth.disconnect_sessions(tokens)
          password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

          {:noreply,
           socket
           |> put_flash(:info, "Password changed successfully.")
           |> assign(:password_form, to_form(password_changeset))}

        {:error, changeset} ->
          {:noreply, assign(socket, :password_form, to_form(changeset, action: :insert))}
      end
    else
      changeset =
        Accounts.change_user_password(user, user_params, hash_password: false)
        |> Ecto.Changeset.add_error(:current_password, "is incorrect")

      {:noreply, assign(socket, :password_form, to_form(changeset, action: :insert))}
    end
  end
end
