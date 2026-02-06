defmodule PavoiWeb.UserInviteController do
  use PavoiWeb, :controller

  alias Pavoi.Accounts
  alias Pavoi.Settings
  alias PavoiWeb.BrandRoutes
  alias PavoiWeb.UserAuth

  def accept(conn, %{"token" => token}) do
    case Accounts.accept_brand_invite(token) do
      {:ok, user, brand} ->
        welcome = "Welcome to #{brand.name || Settings.app_name()}!"
        return_to = BrandRoutes.brand_home_path_for_host(brand, conn.host)

        conn
        |> put_flash(:info, welcome)
        |> put_session(:user_return_to, return_to)
        |> UserAuth.log_in_user(user)

      {:error, :expired} ->
        redirect_with_error(conn, "This invite link has expired.")

      {:error, :accepted} ->
        redirect_with_error(conn, "This invite link has already been used.")

      {:error, :not_found} ->
        redirect_with_error(conn, "This invite link is invalid.")

      {:error, :invalid} ->
        redirect_with_error(conn, "This invite link is invalid.")

      {:error, reason} ->
        redirect_with_error(conn, "Unable to accept invite: #{inspect(reason)}")
    end
  end

  defp redirect_with_error(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/users/log-in")
  end
end
