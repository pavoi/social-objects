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

  alias Pavoi.AI.CommentClassifier
  alias Pavoi.StreamReport
  alias Pavoi.TiktokLive

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"stream_id" => stream_id}}) do
    stream = TiktokLive.get_stream!(stream_id)

    cond do
      # Guard 1: Only send report if stream is still ended
      # (prevents reports if stream was resumed after false end detection)
      stream.status != :ended ->
        Logger.info(
          "Skipping report for stream #{stream_id} - status is #{stream.status} (stream resumed)"
        )

        {:cancel, :stream_not_ended}

      # Guard 2: Only send one report per stream
      # (prevents duplicates if stream ends multiple times due to resume cycles)
      stream.report_sent_at != nil ->
        Logger.info(
          "Skipping report for stream #{stream_id} - already sent at #{stream.report_sent_at}"
        )

        {:cancel, :report_already_sent}

      true ->
        generate_and_send_report(stream_id)
    end
  end

  defp generate_and_send_report(stream_id) do
    # Claim FIRST to prevent multiple workers doing duplicate expensive work
    # (classification, sentiment analysis, GMV API calls)
    case TiktokLive.mark_report_sent(stream_id) do
      {:ok, :marked} ->
        do_generate_and_send_report(stream_id)

      {:error, :already_sent} ->
        Logger.info("Report for stream #{stream_id} claimed by another job")
        {:cancel, :report_already_sent}
    end
  end

  defp do_generate_and_send_report(stream_id) do
    Logger.info("Generating stream report for stream #{stream_id}")

    # Classify comments before generating report
    # This ensures comment sentiment/category data is available for the report
    classify_comments(stream_id)

    with {:ok, report_data} <- StreamReport.generate(stream_id),
         :ok <- validate_sentiment_if_needed(report_data),
         :ok <- persist_gmv_data(stream_id, report_data),
         :ok <- log_report_summary(stream_id, report_data),
         {:ok, :sent} <- StreamReport.send_to_slack(report_data) do
      Logger.info("Stream report sent successfully for stream #{stream_id}")
      :ok
    else
      {:error, :sentiment_missing} ->
        # OpenAI likely failed transiently - clear claim and retry
        Logger.warning(
          "Stream #{stream_id} report missing sentiment analysis (stream has comments), will retry"
        )

        clear_report_sent(stream_id)
        {:error, :sentiment_generation_failed}

      {:error, "Slack not configured" <> _} = error ->
        # Slack not configured - log warning but don't retry
        Logger.warning("Skipping stream report - Slack not configured")
        {:cancel, error}

      {:error, reason} ->
        Logger.error("Failed to send stream report for stream #{stream_id}: #{inspect(reason)}")
        # Clear the claim so retries can try again
        clear_report_sent(stream_id)
        {:error, reason}
    end
  end

  defp log_report_summary(stream_id, report_data) do
    sentiment_length =
      if report_data.sentiment_analysis,
        do: String.length(report_data.sentiment_analysis),
        else: 0

    Logger.info(
      "Stream #{stream_id} report summary: " <>
        "sentiment=#{sentiment_length}chars, " <>
        "products=#{length(report_data.top_products)}, " <>
        "flash_sales=#{length(report_data.flash_sales)}"
    )

    :ok
  end

  # Sentiment should exist if stream had comments (excluding flash sales)
  # If nil or empty when comments exist, OpenAI likely failed - trigger retry
  defp validate_sentiment_if_needed(%{sentiment_analysis: sentiment, stats: %{total_comments: n}})
       when n > 0 do
    cond do
      is_nil(sentiment) ->
        {:error, :sentiment_missing}

      is_binary(sentiment) and String.trim(sentiment) == "" ->
        Logger.warning("Sentiment analysis returned empty string")
        {:error, :sentiment_missing}

      true ->
        :ok
    end
  end

  defp validate_sentiment_if_needed(_report_data), do: :ok

  defp clear_report_sent(stream_id) do
    import Ecto.Query
    alias Pavoi.Repo
    alias Pavoi.TiktokLive.Stream

    from(s in Stream, where: s.id == ^stream_id)
    |> Repo.update_all(set: [report_sent_at: nil])
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

  defp classify_comments(stream_id) do
    # Get flash sale texts to pass to classifier
    flash_sales = StreamReport.detect_flash_sale_comments(stream_id)
    flash_sale_texts = Enum.map(flash_sales, & &1.text)

    case CommentClassifier.classify_stream_comments(stream_id, flash_sale_texts: flash_sale_texts) do
      {:ok, result} ->
        Logger.info(
          "Classified #{result.classified} comments for stream #{stream_id} " <>
            "(#{result.flash_sale} flash sales)"
        )

        :ok

      {:error, reason} ->
        # Log but don't fail - report can still be sent without classification
        Logger.warning(
          "Comment classification failed for stream #{stream_id}: #{inspect(reason)}"
        )

        :ok
    end
  end
end
