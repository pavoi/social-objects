defmodule SocialObjects.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  alias SocialObjects.TiktokLive.StreamReconciler

  @impl true
  def start(_type, _args) do
    children = [
      SocialObjectsWeb.Telemetry,
      SocialObjects.Repo,
      {DNSCluster, query: Application.get_env(:social_objects, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: SocialObjects.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: SocialObjects.Finch},
      # Registry for TikTok Live stream connections and event handlers
      {Registry, keys: :unique, name: SocialObjects.TiktokLive.Registry},
      # Cache for TikTok Shop Analytics API responses
      SocialObjects.TiktokShop.AnalyticsCache,
      # Start Oban for background job processing
      {Oban, Application.fetch_env!(:social_objects, Oban)},
      # Start to serve requests - in dev, this also starts the TikTok Bridge watcher
      SocialObjectsWeb.Endpoint,
      # TikTok Bridge WebSocket client (after Endpoint so watcher can start the bridge first)
      SocialObjects.TiktokLive.BridgeClient,
      # TikTok Bridge health monitor (checks bridge service health periodically)
      SocialObjects.TiktokLive.BridgeHealthMonitor
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SocialObjects.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Run stream reconciliation after startup (production only)
    # This restarts captures for orphaned streams or marks them as ended
    _ =
      if Application.get_env(:social_objects, :env) == :prod do
        _ =
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
    SocialObjectsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
