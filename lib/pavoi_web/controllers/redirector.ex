defmodule PavoiWeb.Redirector do
  @moduledoc """
  Simple controller for redirecting routes.
  """
  use PavoiWeb, :controller

  def redirect_to_sessions(conn, _params) do
    redirect(conn, to: ~p"/sessions")
  end
end
