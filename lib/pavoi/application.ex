defmodule Pavoi.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      PavoiWeb.Telemetry,
      Pavoi.Repo,
      {DNSCluster, query: Application.get_env(:pavoi, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Pavoi.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: Pavoi.Finch},
      # Start Oban for background job processing
      {Oban, Application.fetch_env!(:pavoi, Oban)},
      # Start to serve requests, typically the last entry
      PavoiWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Pavoi.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PavoiWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
