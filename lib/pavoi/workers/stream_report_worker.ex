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

  # Compile-time check for unique opts only (safe since uniqueness is an Oban compile-time concern)
  @unique_opts if Mix.env() == :dev, do: false, else: [period: 300, keys: [:stream_id]]
  @live_check_retry_seconds 120
  @live_check_grace_seconds 120

  use Oban.Worker,
    queue: :slack,
    max_attempts: 3,
    unique: @unique_opts

  require Logger

  alias Pavoi.AI.CommentClassifier
  alias Pavoi.StreamReport
  alias Pavoi.TiktokLive

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"stream_id" => stream_id, "brand_id" => brand_id}}) do
    stream = TiktokLive.get_stream!(brand_id, stream_id)

    case report_guard(stream) do
      :ok -> generate_and_send_report(brand_id, stream_id)
      {:cancel, reason} -> {:cancel, reason}
      {:snooze, seconds} -> {:snooze, seconds}
    end
  end

  defp report_guard(stream) do
    cond do
      # Guard 1: Only send report if stream is still ended
      # (prevents reports if stream was resumed after false end detection)
      stream.status != :ended ->
        Logger.info(
          "Skipping report for stream #{stream.id} - status is #{stream.status} (stream resumed)"
        )

        {:cancel, :stream_not_ended}

      # Guard 2: Only send one report per stream (prod only)
      # (prevents duplicates if stream ends multiple times due to resume cycles)
      # In dev, allow re-sending for testing purposes
      stream.report_sent_at != nil and not dev_mode?() ->
        Logger.info(
          "Skipping report for stream #{stream.id} - already sent at #{stream.report_sent_at}"
        )

        {:cancel, :report_already_sent}

      # Guard 3: Ensure ended_at is set
      # (prevents reports with wrong duration if stream was recovered and ended again
      # but ended_at wasn't updated - race condition between reconciler and mark_stream_ended)
      is_nil(stream.ended_at) ->
        Logger.warning(
          "Stream #{stream.id} has status=ended but ended_at is nil, snoozing to wait for update"
        )

        {:snooze, 30}

      # Guard 4: Skip reports for "false start" streams
      # (very short duration with minimal comments indicates a false end signal from TikTok)
      false_start_stream?(stream) ->
        Logger.info(
          "Skipping report for stream #{stream.id} - appears to be false start " <>
            "(#{stream_duration_seconds(stream)}s, #{stream.total_comments} comments)"
        )

        {:cancel, :false_start}

      true ->
        verify_stream_ended(stream)
    end
  end

  # A "false start" is a stream that ended very quickly with minimal engagement
  # This typically happens when TikTok sends a premature stream_ended event
  # and then the broadcast resumes with a new room_id
  defp false_start_stream?(stream) do
    duration = stream_duration_seconds(stream)
    duration < 120 and stream.total_comments < 10
  end

  defp stream_duration_seconds(%{started_at: started_at, ended_at: ended_at})
       when not is_nil(started_at) and not is_nil(ended_at) do
    DateTime.diff(ended_at, started_at)
  end

  defp stream_duration_seconds(_), do: 0

  defp verify_stream_ended(stream) do
    if live_check_enabled?() do
      case TiktokLive.fetch_room_info(stream.unique_id) do
        {:ok, %{is_live: true, room_id: room_id}} when room_id == stream.room_id ->
          # Confirmed still live with same room - snooze
          Logger.warning("Stream #{stream.id} still live in room #{room_id}, delaying report")

          {:snooze, @live_check_retry_seconds}

        {:ok, %{is_live: true, room_id: room_id}} when is_binary(room_id) ->
          # Different room_id - new stream started, safe to report old one
          Logger.info(
            "Stream #{stream.id} live check: is_live=true but different room_id (#{room_id} vs #{stream.room_id}), proceeding with report"
          )

          enforce_grace_period(stream)

        {:ok, %{is_live: true}} ->
          # Live but no room_id extracted - be conservative, retry
          Logger.warning(
            "Stream #{stream.id} live check: is_live=true but no room_id extracted, retrying"
          )

          {:snooze, @live_check_retry_seconds}

        {:ok, %{is_live: false}} ->
          enforce_grace_period(stream)

        {:error, :room_id_not_found} ->
          enforce_grace_period(stream)

        {:error, reason} ->
          Logger.warning(
            "Stream #{stream.id} live status check failed (#{inspect(reason)}), delaying report"
          )

          {:snooze, @live_check_retry_seconds}
      end
    else
      :ok
    end
  end

  defp enforce_grace_period(%{ended_at: %DateTime{} = ended_at} = stream) do
    elapsed_seconds = DateTime.diff(DateTime.utc_now(), ended_at, :second)

    if elapsed_seconds < @live_check_grace_seconds do
      delay = @live_check_grace_seconds - elapsed_seconds

      Logger.info("Stream #{stream.id} ended #{elapsed_seconds}s ago, delaying report #{delay}s")

      {:snooze, delay}
    else
      :ok
    end
  end

  defp enforce_grace_period(_stream), do: :ok

  defp live_check_enabled? do
    Application.get_env(:pavoi, :verify_stream_live_status, true)
  end

  defp dev_mode? do
    Application.get_env(:pavoi, :env) == :dev
  end

  defp generate_and_send_report(brand_id, stream_id) do
    # Claim FIRST to prevent multiple workers doing duplicate expensive work
    # (classification, sentiment analysis, GMV API calls)
    # In dev, skip the claim to allow re-sending for testing
    if dev_mode?() do
      do_generate_and_send_report(brand_id, stream_id)
    else
      case TiktokLive.mark_report_sent(brand_id, stream_id) do
        {:ok, :marked} ->
          do_generate_and_send_report(brand_id, stream_id)

        {:error, :already_sent} ->
          Logger.info("Report for stream #{stream_id} claimed by another job")
          {:cancel, :report_already_sent}
      end
    end
  end

  defp do_generate_and_send_report(brand_id, stream_id) do
    Logger.info("Generating stream report for stream #{stream_id}")

    # Classify comments before generating report
    # This ensures comment sentiment/category data is available for the report
    classify_comments(brand_id, stream_id)

    with {:ok, report_data} <- StreamReport.generate(brand_id, stream_id),
         :ok <- validate_sentiment_if_needed(report_data),
         :ok <- persist_gmv_data(brand_id, stream_id, report_data),
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

        clear_report_sent(brand_id, stream_id)
        {:error, :sentiment_generation_failed}

      {:error, "Slack not configured" <> _} = error ->
        # Slack not configured - log warning but don't retry
        Logger.warning("Skipping stream report - Slack not configured")
        {:cancel, error}

      {:error, reason} ->
        Logger.error("Failed to send stream report for stream #{stream_id}: #{inspect(reason)}")
        # Clear the claim so retries can try again
        clear_report_sent(brand_id, stream_id)
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

  defp clear_report_sent(brand_id, stream_id) do
    import Ecto.Query
    alias Pavoi.Repo
    alias Pavoi.TiktokLive.Stream

    from(s in Stream, where: s.brand_id == ^brand_id and s.id == ^stream_id)
    |> Repo.update_all(set: [report_sent_at: nil])
  end

  defp persist_gmv_data(_brand_id, _stream_id, %{gmv_data: nil}), do: :ok

  defp persist_gmv_data(brand_id, stream_id, %{gmv_data: gmv_data}) do
    case TiktokLive.update_stream_gmv(brand_id, stream_id, gmv_data) do
      {:ok, _stream} ->
        Logger.info("Persisted GMV data for stream #{stream_id}")
        :ok

      {:error, reason} ->
        Logger.warning("Failed to persist GMV for stream #{stream_id}: #{inspect(reason)}")
        # Don't fail the job if GMV persistence fails
        :ok
    end
  end

  defp classify_comments(brand_id, stream_id) do
    # Get flash sale texts to pass to classifier
    flash_sales = StreamReport.detect_flash_sale_comments(brand_id, stream_id)
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
