defmodule SocialObjects.Workers.CreatorEngagementRankingWorker do
  @moduledoc """
  Daily brand-scoped creator engagement ranking refresh.
  """

  use Oban.Worker,
    queue: :analytics,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing]]

  require Logger

  alias SocialObjects.Creators.EngagementRankings

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"brand_id" => brand_id}}) do
    case EngagementRankings.refresh_brand(brand_id) do
      {:ok, stats} ->
        Logger.info(
          "[CreatorEngagementRankingWorker] Refreshed brand #{brand_id}: #{inspect(stats)}"
        )

        :ok

      {:error, reason} ->
        Logger.error(
          "[CreatorEngagementRankingWorker] Failed for brand #{brand_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
