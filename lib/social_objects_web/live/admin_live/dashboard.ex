defmodule SocialObjectsWeb.AdminLive.Dashboard do
  @moduledoc """
  Admin dashboard with overview stats, quick actions, and system monitoring.

  Provides visibility into:
  - Brand and user counts
  - Feature flags
  - Worker sync statuses
  - Oban queue health
  - Failed job management
  """
  use SocialObjectsWeb, :live_view

  import SocialObjectsWeb.AdminComponents
  import SocialObjectsWeb.FilterComponents
  import SocialObjectsWeb.ParamHelpers

  alias SocialObjects.Catalog
  alias SocialObjects.Monitoring
  alias SocialObjects.TiktokShop
  alias SocialObjects.Workers.Registry
  alias SocialObjects.Workers.Requirements

  @monitoring_refresh_ms 10_000

  @impl true
  def mount(_params, _session, socket) do
    brands = Catalog.list_brands()
    feature_flags = SocialObjects.FeatureFlags.list_all()
    defined_flags = SocialObjects.FeatureFlags.defined_flags()

    # Default to "All Brands"
    selected_brand_id = nil

    # Subscribe to PubSub topics for real-time updates
    _ =
      if connected?(socket) do
        _ = subscribe_to_sync_topics(brands)
        schedule_monitoring_refresh()
      end

    socket =
      socket
      |> assign(:page_title, "Admin Dashboard")
      |> assign(:brands, brands)
      |> assign(:feature_flags, feature_flags)
      |> assign(:defined_flags, defined_flags)
      |> assign(:selected_brand_id, selected_brand_id)
      |> assign(:workers_by_category, Registry.workers_by_category())
      |> load_monitoring_data()

    {:ok, socket}
  end

  # ============================================================================
  # Event Handlers
  # ============================================================================

  @impl true
  def handle_event("toggle_flag", %{"flag" => flag_name}, socket) do
    current = Map.get(socket.assigns.feature_flags, flag_name, true)
    _ = SocialObjects.FeatureFlags.set_flag(flag_name, !current)

    {:noreply,
     socket
     |> assign(:feature_flags, SocialObjects.FeatureFlags.list_all())
     |> put_flash(:info, "Feature flag updated")}
  end

  @impl true
  def handle_event("filter_brand", params, socket) do
    brand_id_param = params["brand_id"] || params["selection"] || "all"

    brand_id =
      case brand_id_param do
        "" -> nil
        "all" -> nil
        id -> parse_id_or_nil(id)
      end

    {:noreply,
     socket
     |> assign(:selected_brand_id, brand_id)
     |> load_monitoring_data()}
  end

  @impl true
  def handle_event("trigger_worker", %{"worker" => worker_key, "brand_id" => brand_id}, socket) do
    brand_id = parse_brand_id(brand_id)

    result =
      with {:ok, brand_id} <- validate_brand_id(brand_id),
           {:ok, worker} <- lookup_triggerable_worker(worker_key),
           {:ok, :ready} <- can_trigger_worker_for_brand?(worker, brand_id) do
        trigger_worker(worker, brand_id)
      end

    {:noreply, handle_trigger_result(socket, result, worker_key)}
  end

  @impl true
  def handle_event("retry_job", %{"job_id" => job_id_param}, socket) do
    case parse_id(job_id_param) do
      {:ok, job_id} ->
        case Monitoring.retry_job(job_id) do
          :ok ->
            {:noreply,
             socket
             |> put_flash(:info, "Job queued for retry")
             |> load_monitoring_data()}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Failed to retry job")}
        end

      :error ->
        {:noreply, put_flash(socket, :error, "Invalid job ID")}
    end
  end

  # ============================================================================
  # PubSub Handlers - refresh UI when worker state changes
  # ============================================================================

  @monitoring_events [
    :sync_started,
    :sync_completed,
    :sync_failed,
    :tiktok_sync_started,
    :tiktok_sync_completed,
    :tiktok_sync_failed,
    :bigquery_sync_started,
    :bigquery_sync_completed,
    :bigquery_sync_failed,
    :enrichment_started,
    :enrichment_completed,
    :enrichment_failed,
    :video_sync_started,
    :video_sync_completed,
    :video_sync_failed,
    :scan_started,
    :scan_completed,
    :product_performance_sync_started,
    :product_performance_sync_completed,
    :product_performance_sync_failed,
    :creator_purchase_sync_started,
    :creator_purchase_sync_completed,
    :creator_purchase_sync_failed,
    :brand_gmv_sync_started,
    :brand_gmv_sync_completed,
    :brand_gmv_sync_failed,
    :stream_analytics_sync_started,
    :stream_analytics_sync_completed,
    :stream_analytics_sync_failed,
    :weekly_recap_sync_started,
    :weekly_recap_sync_completed,
    :weekly_recap_sync_failed,
    :tiktok_token_refresh_started,
    :tiktok_token_refresh_completed,
    :tiktok_token_refresh_failed,
    :gmv_backfill_started,
    :gmv_backfill_completed,
    :gmv_backfill_failed,
    :euka_import_started,
    :euka_import_completed,
    :euka_import_failed
  ]

  @impl true
  def handle_info(:refresh_monitoring, socket) do
    schedule_monitoring_refresh()
    {:noreply, load_monitoring_data(socket)}
  end

  @impl true
  def handle_info(message, socket) do
    if monitoring_update_event?(message) do
      {:noreply, load_monitoring_data(socket)}
    else
      {:noreply, socket}
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  # Trigger worker helpers
  defp validate_brand_id(nil), do: {:error, :no_brand}
  defp validate_brand_id(brand_id), do: {:ok, brand_id}

  defp lookup_triggerable_worker(worker_key) do
    case Registry.get_worker(worker_key) do
      nil -> {:error, {:unknown_worker, worker_key}}
      %{triggerable: false} -> {:error, :not_triggerable}
      worker -> {:ok, worker}
    end
  end

  defp handle_trigger_result(socket, {:ok, _job}, _worker_key) do
    socket
    |> put_flash(:info, "Worker job queued for brand")
    |> load_monitoring_data()
  end

  defp handle_trigger_result(socket, {:error, :no_brand}, _worker_key) do
    put_flash(socket, :error, "Please select a brand to run this worker")
  end

  defp handle_trigger_result(socket, {:error, {:unknown_worker, key}}, _worker_key) do
    put_flash(socket, :error, "Unknown worker: #{key}")
  end

  defp handle_trigger_result(socket, {:error, :not_triggerable}, _worker_key) do
    put_flash(socket, :error, "This worker cannot be manually triggered")
  end

  defp handle_trigger_result(socket, {:error, :missing_hard, missing}, _worker_key) do
    labels = Requirements.requirement_labels(missing) |> Enum.join(", ")
    put_flash(socket, :error, "Missing requirements: #{labels}")
  end

  defp handle_trigger_result(socket, {:error, :unknown_worker}, worker_key) do
    put_flash(socket, :error, "Unknown worker: #{worker_key}")
  end

  defp handle_trigger_result(socket, {:error, reason}, _worker_key) do
    put_flash(socket, :error, "Failed to trigger worker: #{inspect(reason)}")
  end

  defp can_trigger_worker_for_brand?(worker, brand_id) do
    requirements = Map.get(worker, :requirements, [])
    capabilities = Requirements.get_brand_capabilities(brand_id, requirements)
    Requirements.can_run?(worker, capabilities)
  end

  defp subscribe_to_sync_topics(brands) do
    for brand <- brands do
      _ = Phoenix.PubSub.subscribe(SocialObjects.PubSub, "shopify:sync:#{brand.id}")
      _ = Phoenix.PubSub.subscribe(SocialObjects.PubSub, "tiktok:sync:#{brand.id}")
      _ = Phoenix.PubSub.subscribe(SocialObjects.PubSub, "bigquery:sync:#{brand.id}")
      _ = Phoenix.PubSub.subscribe(SocialObjects.PubSub, "creator:enrichment:#{brand.id}")
      _ = Phoenix.PubSub.subscribe(SocialObjects.PubSub, "video:sync:#{brand.id}")
      _ = Phoenix.PubSub.subscribe(SocialObjects.PubSub, "tiktok_live:scan:#{brand.id}")
      _ = Phoenix.PubSub.subscribe(SocialObjects.PubSub, "product_performance:sync:#{brand.id}")
      _ = Phoenix.PubSub.subscribe(SocialObjects.PubSub, "creator_purchase:sync:#{brand.id}")
      _ = Phoenix.PubSub.subscribe(SocialObjects.PubSub, "brand_gmv:sync:#{brand.id}")
      _ = Phoenix.PubSub.subscribe(SocialObjects.PubSub, "stream_analytics:sync:#{brand.id}")
      _ = Phoenix.PubSub.subscribe(SocialObjects.PubSub, "weekly_recap:sync:#{brand.id}")
      _ = Phoenix.PubSub.subscribe(SocialObjects.PubSub, "tiktok_token_refresh:sync:#{brand.id}")
      _ = Phoenix.PubSub.subscribe(SocialObjects.PubSub, "gmv_backfill:sync:#{brand.id}")
      _ = Phoenix.PubSub.subscribe(SocialObjects.PubSub, "euka:import:#{brand.id}")
    end
  end

  defp monitoring_update_event?(message) when is_tuple(message) and tuple_size(message) > 0 do
    elem(message, 0) in @monitoring_events
  end

  defp monitoring_update_event?(_message), do: false

  defp schedule_monitoring_refresh do
    Process.send_after(self(), :refresh_monitoring, @monitoring_refresh_ms)
  end

  defp load_monitoring_data(socket) do
    brand_id = socket.assigns.selected_brand_id

    # Compute capabilities ONCE per brand selection
    capabilities =
      if brand_id,
        do: Requirements.get_brand_capabilities(brand_id),
        else: %{}

    # Compute worker requirements using the unified Requirements module
    worker_requirements = Requirements.compute_all_worker_requirements(capabilities)

    socket
    |> assign(:brand_capabilities, capabilities)
    |> assign(:worker_requirements, worker_requirements)
    |> assign(:worker_statuses, Monitoring.get_all_sync_statuses(brand_id))
    |> assign(:oban_stats, Monitoring.get_oban_queue_stats())
    |> assign(:failed_jobs, Monitoring.get_recent_failed_jobs(brand_id: brand_id, limit: 5))
    |> assign(:running_workers, get_running_workers(brand_id))
    |> assign(:failed_worker_states, get_failed_worker_states(brand_id))
    |> assign(:tiktok_auth_health, get_tiktok_auth_health(brand_id))
    |> assign(:rate_limit_infos, get_rate_limit_infos(brand_id))
  end

  defp get_running_workers(nil), do: []
  defp get_running_workers(brand_id), do: Monitoring.get_running_workers_for_brand(brand_id)

  defp get_failed_worker_states(nil), do: %{}

  defp get_failed_worker_states(brand_id),
    do: Monitoring.get_failed_worker_states_for_brand(brand_id)

  defp get_rate_limit_infos(nil), do: %{}

  defp get_rate_limit_infos(brand_id) do
    %{
      creator_enrichment: Monitoring.get_enrichment_rate_limit_info(brand_id),
      product_performance_sync: Monitoring.get_product_performance_rate_limit_info(brand_id)
    }
  end

  defp get_tiktok_auth_health(nil), do: nil

  defp get_tiktok_auth_health(brand_id) do
    case TiktokShop.get_auth(brand_id) do
      nil ->
        %{status: :missing, expires_at: nil}

      auth ->
        expires_at = auth.access_token_expires_at
        now = DateTime.utc_now()

        status =
          cond do
            is_nil(expires_at) -> :missing
            DateTime.compare(expires_at, now) == :lt -> :expired
            DateTime.diff(expires_at, now, :second) <= 3600 -> :expiring
            true -> :ok
          end

        %{
          status: status,
          expires_at: expires_at,
          shop_name: auth.shop_name,
          shop_code: auth.shop_code
        }
    end
  end

  defp parse_brand_id(nil), do: nil
  defp parse_brand_id(""), do: nil
  defp parse_brand_id(id) when is_binary(id), do: parse_id_or_nil(id)
  defp parse_brand_id(id) when is_integer(id), do: id

  defp trigger_worker(worker, brand_id) do
    args = %{"brand_id" => brand_id}

    worker.module.new(args)
    |> Oban.insert()
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="admin-page">
      <div class="admin-page__header">
        <h1 class="admin-page__title">Dashboard</h1>
      </div>

      <div class="admin-body">
        <div class="admin-panel">
          <div class="admin-panel__header">
            <h2 class="admin-panel__title">Quick Actions</h2>
          </div>
          <div class="admin-panel__body">
            <div class="quick-actions">
              <.button navigate={~p"/admin/users"} variant="primary">
                Manage Users
              </.button>
              <.button navigate={~p"/admin/brands"} variant="primary">
                Manage Brands
              </.button>
            </div>
          </div>
        </div>

        <div class="admin-panel">
          <div class="admin-panel__header">
            <h2 class="admin-panel__title">Feature Flags</h2>
          </div>
          <div class="admin-panel__body">
            <div class="feature-flags">
              <div :for={flag <- @defined_flags} class="feature-flag">
                <div class="feature-flag__info">
                  <span class="feature-flag__label">{flag.label}</span>
                  <span class="feature-flag__description">{flag.description}</span>
                </div>
                <button
                  type="button"
                  phx-click="toggle_flag"
                  phx-value-flag={flag.key}
                  class={"toggle " <> if(Map.get(@feature_flags, flag.key, true), do: "toggle--on", else: "toggle--off")}
                  role="switch"
                  aria-checked={to_string(Map.get(@feature_flags, flag.key, true))}
                >
                  <span class="toggle__track"><span class="toggle__thumb"></span></span>
                </button>
              </div>
            </div>
          </div>
        </div>

        <div class="monitoring-panel">
          <div class="monitoring-panel__header">
            <h2 class="monitoring-panel__title">System Monitoring</h2>
            <div class="brand-filter">
              <label class="brand-filter__label">Brand:</label>
              <.hover_dropdown
                id="admin-brand-filter"
                options={Enum.map(@brands, &{&1.id, &1.name})}
                trigger_label="All Brands"
                current_value={@selected_brand_id}
                change_event="filter_brand"
                clear_event="filter_brand"
              />
            </div>
          </div>
          <div class="monitoring-panel__body">
            <.queue_health_stats stats={@oban_stats} />

            <div :if={@selected_brand_id}>
              <.tiktok_auth_status_banner auth={@tiktok_auth_health} />

              <.worker_category_panel
                :for={{category, workers} <- @workers_by_category}
                category={category}
                label={Registry.category_label(category)}
                workers={workers}
                statuses={@worker_statuses}
                running_workers={@running_workers}
                failed_worker_states={@failed_worker_states}
                worker_requirements={@worker_requirements}
                rate_limit_infos={@rate_limit_infos}
                brand_id={@selected_brand_id}
              />
            </div>

            <div :if={is_nil(@selected_brand_id)} class="monitoring-empty">
              <p>Select a brand to view worker statuses and trigger syncs.</p>
            </div>

            <.failed_jobs_table jobs={@failed_jobs} />
          </div>
        </div>
      </div>
    </div>
    """
  end
end
