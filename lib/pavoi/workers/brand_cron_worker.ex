defmodule Pavoi.Workers.BrandCronWorker do
  @moduledoc """
  Enqueues per-brand background jobs for scheduled cron tasks.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  alias Pavoi.Catalog

  alias Pavoi.Workers.{
    BigQueryOrderSyncWorker,
    CreatorEnrichmentWorker,
    ShopifySyncWorker,
    TiktokLiveMonitorWorker,
    TiktokSyncWorker,
    TiktokTokenRefreshWorker
  }

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task" => task}}) do
    Catalog.list_brands()
    |> Enum.each(&enqueue_for_brand(task, &1.id))

    :ok
  end

  defp enqueue_for_brand("shopify_sync", brand_id) do
    %{"brand_id" => brand_id}
    |> ShopifySyncWorker.new()
    |> Oban.insert()
  end

  defp enqueue_for_brand("tiktok_sync", brand_id) do
    %{"brand_id" => brand_id}
    |> TiktokSyncWorker.new()
    |> Oban.insert()
  end

  defp enqueue_for_brand("bigquery_sync", brand_id) do
    %{"brand_id" => brand_id, "source" => "cron"}
    |> BigQueryOrderSyncWorker.new()
    |> Oban.insert()
  end

  defp enqueue_for_brand("tiktok_token_refresh", brand_id) do
    %{"brand_id" => brand_id}
    |> TiktokTokenRefreshWorker.new()
    |> Oban.insert()
  end

  defp enqueue_for_brand("tiktok_live_monitor", brand_id) do
    %{"brand_id" => brand_id, "source" => "cron"}
    |> TiktokLiveMonitorWorker.new()
    |> Oban.insert()
  end

  defp enqueue_for_brand("creator_enrichment", brand_id) do
    %{"brand_id" => brand_id, "source" => "cron"}
    |> CreatorEnrichmentWorker.new()
    |> Oban.insert()
  end

  defp enqueue_for_brand(_task, _brand_id), do: :ok
end
