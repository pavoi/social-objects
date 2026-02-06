defmodule Pavoi.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  alias Pavoi.TiktokLive.StreamReconciler

  @impl true
  def start(_type, _args) do
    children = [
      PavoiWeb.Telemetry,
      Pavoi.Repo,
      {DNSCluster, query: Application.get_env(:pavoi, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Pavoi.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: Pavoi.Finch},
      # Registry for TikTok Live stream connections and event handlers
      {Registry, keys: :unique, name: Pavoi.TiktokLive.Registry},
      # Start Oban for background job processing
      {Oban, Application.fetch_env!(:pavoi, Oban)},
      # Start to serve requests - in dev, this also starts the TikTok Bridge watcher
      PavoiWeb.Endpoint,
      # TikTok Bridge WebSocket client (after Endpoint so watcher can start the bridge first)
      Pavoi.TiktokLive.BridgeClient,
      # TikTok Bridge health monitor (checks bridge service health periodically)
      Pavoi.TiktokLive.BridgeHealthMonitor
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Pavoi.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Run stream reconciliation after startup (production only)
    # This restarts captures for orphaned streams or marks them as ended
    if Application.get_env(:pavoi, :env) == :prod do
      spawn(fn ->
        # Give the app a moment to fully start
        Process.sleep(5_000)

        try do
          count = StreamReconciler.run()
          Logger.info("Stream reconciliation completed, processed #{count} jobs/streams")
        rescue
          e ->
            Logger.error("Stream reconciliation failed: #{Exception.message(e)}")
            Logger.error(Exception.format_stacktrace(__STACKTRACE__))
        end
      end)
    end

    result
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PavoiWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
