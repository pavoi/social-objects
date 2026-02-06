defmodule PavoiWeb.HomeController do
  use PavoiWeb, :controller

  alias Pavoi.Accounts
  alias Pavoi.Accounts.Scope
  alias Pavoi.Catalog.Brand
  alias PavoiWeb.BrandRoutes

  def index(conn, _params) do
    case conn.assigns.current_scope do
      %Scope{user: user} ->
        case Accounts.get_default_brand_for_user(user) do
          %Brand{} = brand ->
            redirect_to_brand(conn, brand)

          nil ->
            conn
            |> put_flash(:error, "No brands are assigned to your account.")
            |> redirect(to: ~p"/users/log-in")
        end

      _ ->
        redirect(conn, to: ~p"/users/log-in")
    end
  end

  defp redirect_to_brand(conn, brand) do
    path = BrandRoutes.brand_home_path(brand, conn.host)

    if String.starts_with?(path, "http") do
      redirect(conn, external: path)
    else
      redirect(conn, to: path)
    end
  end
end
