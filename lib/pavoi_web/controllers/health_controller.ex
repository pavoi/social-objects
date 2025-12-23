defmodule PavoiWeb.HealthController do
  @moduledoc """
  Health check endpoint for load balancers and deployment health checks.

  This endpoint intentionally does NOT check database connectivity to ensure
  it remains available even during schema migrations or database issues.
  """
  use PavoiWeb, :controller

  def check(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{status: "ok", timestamp: DateTime.utc_now()}))
  end
end
