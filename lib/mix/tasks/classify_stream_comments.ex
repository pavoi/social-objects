defmodule Mix.Tasks.ClassifyStreamComments do
  @moduledoc """
  Classify comments for TikTok Live streams using AI.

  This task uses GPT-4o-mini to classify each comment by sentiment (positive/neutral/negative)
  and category (concern, product request, question, technical issue, praise, or general).

  ## Usage

      # Classify comments for all streams that have unclassified comments
      mix classify_stream_comments --all

      # Classify comments for a specific stream
      mix classify_stream_comments --stream 42

      # Preview what would be processed (dry run)
      mix classify_stream_comments --all --dry-run

  ## Options

      --all          Process all streams with unclassified comments
      --stream ID    Process a specific stream by ID
      --dry-run      Preview what would be processed without calling the AI
      --batch-size   Number of comments per API call (default: 50)

  ## Cost Estimate

  Using GPT-4o-mini at ~$0.03 per 1,500 comments (batch of 50 at a time).
  """

  use Mix.Task
  require Logger
  import Ecto.Query

  alias Pavoi.AI.CommentClassifier
  alias Pavoi.Repo
  alias Pavoi.StreamReport
  alias Pavoi.TiktokLive
  alias Pavoi.TiktokLive.Stream

  @shortdoc "Classify TikTok Live stream comments with AI"

  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [all: :boolean, stream: :integer, dry_run: :boolean, batch_size: :integer],
        aliases: [a: :all, s: :stream, d: :dry_run, b: :batch_size]
      )

    dry_run = Keyword.get(opts, :dry_run, false)
    batch_size = Keyword.get(opts, :batch_size, 50)

    cond do
      Keyword.get(opts, :all) ->
        process_all_streams(dry_run, batch_size)

      stream_id = Keyword.get(opts, :stream) ->
        process_stream(stream_id, dry_run, batch_size)

      true ->
        Mix.shell().error("Please specify --all or --stream ID")
        Mix.shell().info("Run 'mix help classify_stream_comments' for usage")
    end
  end

  defp process_all_streams(dry_run, batch_size) do
    Mix.shell().info("Finding streams with unclassified comments...")

    # Get all ended streams
    streams =
      from(s in Stream,
        where: s.status == :ended,
        order_by: [asc: s.id]
      )
      |> Repo.all()

    # Filter to those with unclassified comments
    streams_to_process =
      streams
      |> Enum.map(fn stream ->
        total = TiktokLive.count_stream_comments(stream.id)
        classified = TiktokLive.count_classified_comments(stream.id)
        unclassified = total - classified

        %{
          stream: stream,
          total: total,
          classified: classified,
          unclassified: unclassified
        }
      end)
      |> Enum.filter(fn s -> s.unclassified > 0 end)

    if Enum.empty?(streams_to_process) do
      Mix.shell().info("All streams already have classified comments!")
      return_stats(%{streams: 0, comments: 0})
    else
      process_found_streams(streams_to_process, dry_run, batch_size)
    end
  end

  defp process_found_streams(streams_to_process, dry_run, batch_size) do
    total_unclassified =
      Enum.reduce(streams_to_process, 0, fn s, acc -> acc + s.unclassified end)

    print_streams_summary(streams_to_process, total_unclassified)

    if dry_run do
      print_dry_run_preview(streams_to_process)
      return_stats(%{streams: length(streams_to_process), comments: total_unclassified})
    else
      results = process_streams_batch(streams_to_process, batch_size)
      print_summary(results)
    end
  end

  defp print_streams_summary(streams_to_process, total_unclassified) do
    Mix.shell().info("")

    Mix.shell().info(
      "Found #{length(streams_to_process)} streams with #{total_unclassified} unclassified comments"
    )

    Mix.shell().info("")

    estimated_cost = total_unclassified * 0.03 / 1500
    Mix.shell().info("Estimated cost: $#{Float.round(estimated_cost, 2)}")
    Mix.shell().info("")
  end

  defp print_dry_run_preview(streams_to_process) do
    Mix.shell().info("[DRY RUN] Would process:")

    Enum.each(streams_to_process, fn s ->
      Mix.shell().info("  Stream ##{s.stream.id}: #{s.unclassified} comments to classify")
    end)
  end

  defp process_streams_batch(streams_to_process, batch_size) do
    Enum.reduce(streams_to_process, %{success: 0, failed: 0, comments: 0}, fn s, acc ->
      Mix.shell().info("Processing stream ##{s.stream.id} (#{s.unclassified} comments)...")
      process_single_stream_result(s.stream.id, batch_size, acc)
    end)
  end

  defp process_single_stream_result(stream_id, batch_size, acc) do
    case process_stream_internal(stream_id, batch_size) do
      {:ok, result} ->
        Mix.shell().info("  Classified: #{result.classified}, Flash sales: #{result.flash_sale}")

        %{
          acc
          | success: acc.success + 1,
            comments: acc.comments + result.classified + result.flash_sale
        }

      {:error, reason} ->
        Mix.shell().error("  Failed: #{inspect(reason)}")
        %{acc | failed: acc.failed + 1}
    end
  end

  defp process_stream(stream_id, dry_run, batch_size) do
    case TiktokLive.get_stream(stream_id) do
      nil ->
        Mix.shell().error("Stream ##{stream_id} not found")
        return_stats(%{streams: 0, comments: 0})

      _stream ->
        do_process_stream(stream_id, dry_run, batch_size)
    end
  end

  defp do_process_stream(stream_id, dry_run, batch_size) do
    total = TiktokLive.count_stream_comments(stream_id)
    classified = TiktokLive.count_classified_comments(stream_id)
    unclassified = total - classified

    Mix.shell().info(
      "Stream ##{stream_id}: #{total} comments, #{classified} classified, #{unclassified} unclassified"
    )

    classify_if_needed(stream_id, unclassified, dry_run, batch_size)
  end

  defp classify_if_needed(_stream_id, 0, _dry_run, _batch_size) do
    Mix.shell().info("All comments already classified!")
    return_stats(%{streams: 1, comments: 0})
  end

  defp classify_if_needed(_stream_id, unclassified, true, _batch_size) do
    Mix.shell().info("[DRY RUN] Would classify #{unclassified} comments")
    return_stats(%{streams: 1, comments: unclassified})
  end

  defp classify_if_needed(stream_id, _unclassified, false, batch_size) do
    case process_stream_internal(stream_id, batch_size) do
      {:ok, result} ->
        Mix.shell().info("Classified: #{result.classified}, Flash sales: #{result.flash_sale}")
        return_stats(%{streams: 1, comments: result.classified + result.flash_sale})

      {:error, reason} ->
        Mix.shell().error("Failed: #{inspect(reason)}")
        return_stats(%{streams: 1, comments: 0})
    end
  end

  defp process_stream_internal(stream_id, batch_size) do
    # Detect flash sales first
    flash_sales = StreamReport.detect_flash_sale_comments(stream_id)
    flash_sale_texts = Enum.map(flash_sales, & &1.text)

    CommentClassifier.classify_stream_comments(stream_id,
      flash_sale_texts: flash_sale_texts,
      batch_size: batch_size
    )
  end

  defp return_stats(stats), do: stats

  defp print_summary(results) do
    Mix.shell().info("""

    ========================================
    Classification Complete!
    ========================================

    Streams processed successfully: #{results.success}
    Streams failed: #{results.failed}
    Total comments classified: #{results.comments}
    """)
  end
end
