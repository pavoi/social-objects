defmodule PavoiWeb.UserSessionController do
  use PavoiWeb, :controller

  alias Pavoi.Accounts
  alias PavoiWeb.UserAuth

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, "User confirmed successfully.")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  # GET magic link - logs user in directly when clicking the email link
  def create_from_token(conn, %{"token" => token}) do
    # Check if user exists and was unconfirmed before we consume the token
    with user when not is_nil(user) <- Accounts.get_user_by_magic_link_token(token),
         was_unconfirmed = is_nil(user.confirmed_at),
         {:ok, {user, tokens_to_disconnect}} <- Accounts.login_user_by_magic_link(token) do
      UserAuth.disconnect_sessions(tokens_to_disconnect)
      message = if was_unconfirmed, do: "User confirmed successfully.", else: "Welcome back!"

      conn
      |> put_flash(:info, message)
      |> UserAuth.log_in_user(user, %{"remember_me" => "true"})
    else
      _ ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # POST magic link login - always remember the user since there's no checkbox
  defp create(conn, %{"user" => %{"token" => token}}, info) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, %{"remember_me" => "true"})

      _ ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  defp create(conn, _params, _info) do
    conn
    |> put_flash(:error, "The link is invalid or it has expired.")
    |> redirect(to: ~p"/users/log-in")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
