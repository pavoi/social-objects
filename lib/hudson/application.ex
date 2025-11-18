defmodule Hudson.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    neon_enabled? = neon_enabled?()

    children =
      [
        HudsonWeb.Telemetry,
        Hudson.LocalRepo,
        {DNSCluster, query: Application.get_env(:hudson, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Hudson.PubSub},
        HudsonWeb.Endpoint
      ]
      |> maybe_add_neon(neon_enabled?)
      |> maybe_add_oban(neon_enabled?)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Hudson.Supervisor]
    {:ok, supervisor_pid} = Supervisor.start_link(children, opts)

    Hudson.LocalRepoMigrator.migrate()
    Hudson.RuntimeSmoke.check_nifs()

    {:ok, supervisor_pid}
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HudsonWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp neon_enabled? do
    value = System.get_env("HUDSON_ENABLE_NEON", "true") |> String.downcase()
    value in ["true", "1", "yes"]
  end

  defp maybe_add_neon(children, true), do: [Hudson.Repo | children]

  defp maybe_add_neon(children, false) do
    Logger.info("🔌 HUDSON_ENABLE_NEON=false; skipping Hudson.Repo for offline-first boot")
    children
  end

  defp maybe_add_oban(children, true),
    do: [{Oban, Application.fetch_env!(:hudson, Oban)} | children]

  defp maybe_add_oban(children, false) do
    Logger.info("🔌 HUDSON_ENABLE_NEON=false; skipping Oban startup")
    children
  end
end
