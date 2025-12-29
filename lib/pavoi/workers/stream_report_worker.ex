defmodule Pavoi.Workers.StreamReportWorker do
  @moduledoc """
  Oban worker that generates and sends Slack reports when TikTok Live streams end.

  The report includes:
  - Stream cover image (if captured)
  - Stream statistics (duration, viewers, likes, gifts, comments)
  - Top 5 products referenced in comments
  - Flash sale activity summary
  - AI-powered sentiment analysis of comments

  ## Job Arguments
  - `stream_id` - ID of the completed stream
  """

  @unique_opts if Mix.env() == :dev, do: false, else: [period: 300, keys: [:stream_id]]

  use Oban.Worker,
    queue: :slack,
    max_attempts: 3,
    unique: @unique_opts

  require Logger

  alias Pavoi.StreamReport
  alias Pavoi.TiktokLive

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"stream_id" => stream_id}}) do
    Logger.info("Generating stream report for stream #{stream_id}")

    with {:ok, report_data} <- StreamReport.generate(stream_id),
         :ok <- persist_gmv_data(stream_id, report_data),
         {:ok, :sent} <- StreamReport.send_to_slack(report_data) do
      Logger.info("Stream report sent successfully for stream #{stream_id}")
      :ok
    else
      {:error, "Slack not configured" <> _} = error ->
        # Slack not configured - log warning but don't retry
        Logger.warning("Skipping stream report - Slack not configured")
        {:cancel, error}

      {:error, reason} ->
        Logger.error("Failed to send stream report for stream #{stream_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp persist_gmv_data(_stream_id, %{gmv_data: nil}), do: :ok

  defp persist_gmv_data(stream_id, %{gmv_data: gmv_data}) do
    case TiktokLive.update_stream_gmv(stream_id, gmv_data) do
      {:ok, _stream} ->
        Logger.info("Persisted GMV data for stream #{stream_id}")
        :ok

      {:error, reason} ->
        Logger.warning("Failed to persist GMV for stream #{stream_id}: #{inspect(reason)}")
        # Don't fail the job if GMV persistence fails
        :ok
    end
  end
end
