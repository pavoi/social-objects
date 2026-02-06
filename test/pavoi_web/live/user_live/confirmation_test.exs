defmodule PavoiWeb.UserSessionController.MagicLinkTest do
  use PavoiWeb.ConnCase, async: true

  import Pavoi.AccountsFixtures

  alias Pavoi.Accounts

  setup do
    %{unconfirmed_user: unconfirmed_user_fixture(), confirmed_user: user_fixture()}
  end

  describe "magic link login" do
    test "logs in unconfirmed user and confirms them", %{conn: conn, unconfirmed_user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      conn = get(conn, ~p"/users/log-in/#{token}")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "User confirmed successfully"
      assert Accounts.get_user!(user.id).confirmed_at
      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
    end

    test "logs in confirmed user", %{conn: conn, confirmed_user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      conn = get(conn, ~p"/users/log-in/#{token}")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"
      assert Accounts.get_user!(user.id).confirmed_at == user.confirmed_at
      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
    end

    test "token can only be used once", %{conn: conn, confirmed_user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      conn = get(conn, ~p"/users/log-in/#{token}")
      assert get_session(conn, :user_token)

      # Try to use the same token again
      conn = build_conn() |> get(~p"/users/log-in/#{token}")

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "The link is invalid or it has expired"

      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "redirects with error for invalid token", %{conn: conn} do
      conn = get(conn, ~p"/users/log-in/invalid-token")

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "The link is invalid or it has expired"

      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end
end
