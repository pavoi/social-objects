defmodule SocialObjects.TiktokLive.BridgeHealthMonitor do
  @moduledoc """
  Periodically monitors the TikTok Bridge service health.

  Checks the bridge's /health endpoint every minute and logs warnings
  if the bridge is unhealthy or unreachable.
  """

  use GenServer

  require Logger

  alias SocialObjects.TiktokLive.BridgeClient

  @check_interval_ms 60_000
  @consecutive_failures_alert 3

  defmodule State do
    @moduledoc false
    defstruct [
      :timer_ref,
      :consecutive_failures,
      :last_healthy_at
    ]
  end

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    if bridge_configured?() do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      Logger.debug("Bridge not configured, skipping health monitor")
      :ignore
    end
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @doc """
  Returns the current health status.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  catch
    :exit, _ -> {:error, :not_running}
  end

  # Server callbacks

  @impl GenServer
  def init(_opts) do
    state = %State{
      consecutive_failures: 0,
      last_healthy_at: nil
    }

    # Schedule first check after a brief delay
    timer_ref = Process.send_after(self(), :check_health, 5_000)

    {:ok, %{state | timer_ref: timer_ref}}
  end

  @impl GenServer
  def handle_info(:check_health, state) do
    new_state = perform_health_check(state)
    timer_ref = Process.send_after(self(), :check_health, @check_interval_ms)
    {:noreply, %{new_state | timer_ref: timer_ref}}
  end

  @impl GenServer
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    status = %{
      healthy: state.consecutive_failures == 0,
      consecutive_failures: state.consecutive_failures,
      last_healthy_at: state.last_healthy_at
    }

    {:reply, status, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    _ = if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    :ok
  end

  # Private functions

  defp perform_health_check(state) do
    case BridgeClient.health() do
      {:ok, _} ->
        if state.consecutive_failures > 0 do
          Logger.info(
            "TikTok Bridge is healthy again after #{state.consecutive_failures} failures"
          )
        end

        %{state | consecutive_failures: 0, last_healthy_at: DateTime.utc_now()}

      {:error, reason} ->
        new_failures = state.consecutive_failures + 1

        if new_failures == 1 do
          Logger.warning("TikTok Bridge health check failed: #{inspect(reason)}")
        end

        if new_failures == @consecutive_failures_alert do
          Logger.error(
            "TikTok Bridge has been unhealthy for #{new_failures} consecutive checks. " <>
              "Stream capture may be affected."
          )
        end

        %{state | consecutive_failures: new_failures}
    end
  end

  defp bridge_configured? do
    enabled = Application.get_env(:social_objects, :tiktok_bridge_enabled, true)
    url = Application.get_env(:social_objects, :tiktok_bridge_url)
    enabled and not is_nil(url) and url != ""
  end
end
