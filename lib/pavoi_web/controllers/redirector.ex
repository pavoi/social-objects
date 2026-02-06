defmodule PavoiWeb.Redirector do
  @moduledoc """
  Simple controller for redirecting routes.
  """
  use PavoiWeb, :controller

  alias Pavoi.Accounts
  alias Pavoi.Accounts.Scope
  alias Pavoi.Catalog
  alias PavoiWeb.BrandRoutes

  def redirect_to_product_sets(conn, _params) do
    with {:ok, brand} <- resolve_brand(conn),
         :ok <- ensure_brand_access(conn, brand) do
      redirect_to_brand_path(conn, BrandRoutes.brand_path(brand, "/product-sets", conn.host))
    else
      _ -> redirect(conn, to: ~p"/users/log-in")
    end
  end

  def redirect_to_product_sets_products(conn, _params) do
    with {:ok, brand} <- resolve_brand(conn),
         :ok <- ensure_brand_access(conn, brand) do
      redirect_to_brand_path(
        conn,
        BrandRoutes.brand_path(brand, "/product-sets?tab=products", conn.host)
      )
    else
      _ -> redirect(conn, to: ~p"/users/log-in")
    end
  end

  defp resolve_brand(conn) do
    slug = conn.params["brand_slug"]
    host = conn.host

    brand =
      cond do
        is_binary(slug) -> Catalog.get_brand_by_slug(slug)
        is_binary(host) -> Catalog.get_brand_by_domain(host) || fallback_brand_for_host(host)
        true -> nil
      end

    case brand do
      nil -> {:error, :brand_not_found}
      brand -> {:ok, brand}
    end
  end

  defp ensure_brand_access(conn, brand) do
    case conn.assigns[:current_scope] do
      %Scope{user: user} when not is_nil(user) ->
        if Accounts.user_has_brand_access?(user, brand) do
          :ok
        else
          {:error, :unauthorized}
        end

      _ ->
        {:error, :unauthenticated}
    end
  end

  defp fallback_brand_for_host(host) when is_binary(host) do
    default_slug = Application.get_env(:pavoi, :default_brand_slug)
    host = String.downcase(host)

    if default_slug && host in ["localhost", "127.0.0.1"] do
      Catalog.get_brand_by_slug(default_slug)
    end
  end

  defp redirect_to_brand_path(conn, path) do
    if String.starts_with?(path, "http") do
      redirect(conn, external: path)
    else
      redirect(conn, to: path)
    end
  end
end
