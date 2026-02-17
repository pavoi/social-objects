defmodule SocialObjects.Workers.BrandCronWorker do
  @moduledoc """
  Enqueues per-brand background jobs for scheduled cron tasks.

  This worker uses the unified Requirements system to determine which brands
  are eligible for each task. The same `Requirements.can_run?/2` function is
  used by both this scheduler and the manual trigger UI, ensuring consistency.

  ## How it works

  1. Cron triggers this worker with a task name (e.g., "tiktok_sync")
  2. We look up the worker definition in the Registry
  3. For each brand, we compute capabilities once and check requirements
  4. Jobs are only enqueued for brands that meet all hard requirements

  ## Fail-closed behavior

  Unknown tasks are discarded with an error log rather than silently ignored.
  This helps surface configuration issues early.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  require Logger

  alias SocialObjects.Catalog
  alias SocialObjects.Workers.Registry
  alias SocialObjects.Workers.Requirements

  @task_to_worker_key %{
    "shopify_sync" => :shopify_sync,
    "tiktok_sync" => :tiktok_sync,
    "bigquery_sync" => :bigquery_order_sync,
    "tiktok_token_refresh" => :tiktok_token_refresh,
    "tiktok_live_monitor" => :tiktok_live_monitor,
    "creator_enrichment" => :creator_enrichment,
    "stream_analytics_sync" => :stream_analytics_sync,
    "weekly_stream_recap" => :weekly_stream_recap,
    "video_sync" => :video_sync,
    "product_performance_sync" => :product_performance_sync,
    "brand_gmv_sync" => :brand_gmv_sync,
    "creator_purchase_sync" => :creator_purchase_sync
  }

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task" => task}}) do
    worker_key = Map.get(@task_to_worker_key, task)

    case get_worker(worker_key, task) do
      {:error, :unknown_task} ->
        Logger.error("[BrandCron] Unknown task: #{task}")
        {:discard, :unknown_task}

      {:ok, worker} ->
        enqueue_for_all_brands(worker)
        :ok
    end
  end

  # Lookup worker, handling unknown tasks
  defp get_worker(nil, _task), do: {:error, :unknown_task}

  defp get_worker(worker_key, task) do
    case Registry.get_worker(worker_key) do
      nil ->
        Logger.error(
          "[BrandCron] Worker key #{worker_key} for task #{task} not found in registry"
        )

        {:error, :unknown_task}

      worker ->
        {:ok, worker}
    end
  end

  # Enqueue jobs for all eligible brands
  defp enqueue_for_all_brands(worker) do
    requirements = Map.get(worker, :requirements, [])

    Catalog.list_brands()
    |> Enum.each(fn brand ->
      # Compute only capabilities required by this worker
      capabilities = Requirements.get_brand_capabilities(brand.id, requirements)
      maybe_enqueue_for_brand(worker, brand.id, capabilities)
    end)
  end

  # Use the SAME gate function as manual trigger
  defp maybe_enqueue_for_brand(worker, brand_id, capabilities) do
    case Requirements.can_run?(worker, capabilities) do
      {:ok, :ready} ->
        args = build_job_args(worker.key, brand_id)

        worker.module.new(args)
        |> Oban.insert()

      {:error, :missing_hard, missing} ->
        Logger.debug(
          "[BrandCron] Skipping #{worker.key} for brand #{brand_id}: missing #{inspect(missing)}"
        )

        :ok

      {:error, :unknown_worker} ->
        Logger.error("[BrandCron] Unknown worker: #{worker.key}")
        :ok
    end
  end

  # Build job arguments - some workers need extra params
  defp build_job_args(:bigquery_order_sync, brand_id) do
    %{"brand_id" => brand_id, "source" => "cron"}
  end

  defp build_job_args(:tiktok_live_monitor, brand_id) do
    %{"brand_id" => brand_id, "source" => "cron"}
  end

  defp build_job_args(:creator_enrichment, brand_id) do
    %{"brand_id" => brand_id, "source" => "cron"}
  end

  defp build_job_args(_worker_key, brand_id) do
    %{"brand_id" => brand_id}
  end
end
