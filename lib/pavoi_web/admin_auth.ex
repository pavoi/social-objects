defmodule PavoiWeb.AdminAuth do
  @moduledoc """
  Authentication helpers for platform admin access.
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  alias Pavoi.Accounts

  @doc """
  Requires the current user to be a platform admin.
  Used as an on_mount hook in admin live_sessions.
  """
  def on_mount(:require_admin, _params, _session, socket) do
    user =
      case socket.assigns[:current_scope] do
        %{user: user} -> user
        _ -> nil
      end

    if user && Accounts.platform_admin?(user) do
      # Load user's brands for the navbar
      user_brands = Accounts.list_user_brands(user)
      default_brand = if user_brands != [], do: hd(user_brands).brand, else: nil

      socket =
        socket
        |> assign(:user_brands, user_brands)
        |> assign(:current_brand, default_brand)
        |> assign(:current_host, nil)

      {:cont, socket}
    else
      socket =
        socket
        |> put_flash(:error, "You must be an admin to access this page.")
        |> redirect(to: "/")

      {:halt, socket}
    end
  end
end
