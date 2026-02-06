defmodule PavoiWeb.UserLive.LoginTest do
  use PavoiWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Pavoi.AccountsFixtures

  describe "login page" do
    test "renders login page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/log-in")

      assert has_element?(view, "#login_form_magic")
      assert has_element?(view, "h1", "Log in")
      assert has_element?(view, "p", "Need access? Contact your admin for an invite.")
      assert has_element?(view, "button", "Send magic link")
    end
  end

  describe "user login - magic link" do
    test "sends magic link email when user exists", %{conn: conn} do
      user = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", user: %{email: user.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "If your email is in our system"

      assert Pavoi.Repo.get_by!(Pavoi.Accounts.UserToken, user_id: user.id).context ==
               "login"
    end

    test "does not disclose if user is registered", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", user: %{email: "idonotexist@example.com"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "If your email is in our system"
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      user = user_fixture()
      %{user: user, conn: log_in_user(conn, user)}
    end

    test "shows login page with email filled in", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/log-in")

      assert has_element?(view, "#login_form_magic")
      assert has_element?(view, "p", "You need to reauthenticate")
      refute has_element?(view, "p", "Need access? Contact your admin for an invite.")
      assert has_element?(view, "button", "Send magic link")

      assert has_element?(view, ~s(#login_form_magic input[name="user[email]"]))
    end
  end
end
