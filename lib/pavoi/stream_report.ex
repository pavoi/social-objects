defmodule Pavoi.StreamReport do
  @moduledoc """
  Generates comprehensive reports for completed TikTok Live streams.

  Reports include:
  - High-level stats (duration, viewers, likes, gifts, comments)
  - Top products referenced in comments (linked to session)
  - Flash sale activity detection
  - AI-powered sentiment analysis of comments
  """

  import Ecto.Query, warn: false
  require Logger

  alias Pavoi.AI.OpenAIClient
  alias Pavoi.Repo
  alias Pavoi.TiktokLive
  alias Pavoi.TiktokLive.Comment

  @flash_sale_threshold 10
  @max_comments_for_ai 200

  @doc """
  Generates report data for a completed stream.

  Returns `{:ok, report_data}` with a map containing:
  - `:stream` - The stream record
  - `:stats` - High-level statistics
  - `:top_products` - Top 5 products by comment mentions
  - `:flash_sales` - Detected flash sale comments
  - `:sentiment_analysis` - AI-generated insights (or nil if failed)
  """
  def generate(stream_id) do
    stream = TiktokLive.get_stream!(stream_id)

    # Auto-link to session if not already linked
    TiktokLive.auto_link_stream_to_session(stream_id)

    # Get basic stats
    stats = get_stats(stream)

    # Get product interest (if linked to session)
    products = get_top_products(stream_id)

    # Detect flash sale comments
    flash_sales = detect_flash_sale_comments(stream_id)

    # Get comments for AI analysis (excluding flash sales)
    comments = get_comments_for_analysis(stream_id, flash_sales)

    # Generate AI sentiment analysis
    sentiment = generate_sentiment_analysis(comments)

    {:ok,
     %{
       stream: stream,
       stats: stats,
       top_products: products,
       flash_sales: flash_sales,
       sentiment_analysis: sentiment
     }}
  end

  defp get_stats(stream) do
    duration = calculate_duration(stream.started_at, stream.ended_at)
    comment_count = TiktokLive.count_stream_comments(stream.id)

    %{
      duration: duration,
      duration_formatted: format_duration(duration),
      peak_viewers: stream.viewer_count_peak || 0,
      total_likes: stream.total_likes || 0,
      total_gifts_value: stream.total_gifts_value || 0,
      total_comments: comment_count
    }
  end

  defp calculate_duration(started_at, ended_at) do
    if started_at && ended_at do
      DateTime.diff(ended_at, started_at, :second)
    else
      0
    end
  end

  defp format_duration(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m"
      minutes > 0 -> "#{minutes}m"
      true -> "< 1m"
    end
  end

  defp get_top_products(stream_id) do
    case TiktokLive.get_linked_sessions(stream_id) do
      [session | _] ->
        TiktokLive.get_product_interest_summary(stream_id, session.id)
        |> Enum.take(5)

      [] ->
        []
    end
  end

  @doc """
  Detects flash sale comments - those appearing many times with identical text.

  Returns a list of `%{text: string, count: integer}` sorted by count descending.
  """
  def detect_flash_sale_comments(stream_id) do
    from(c in Comment,
      where: c.stream_id == ^stream_id,
      group_by: c.comment_text,
      having: count(c.id) >= ^@flash_sale_threshold,
      select: %{text: c.comment_text, count: count(c.id)},
      order_by: [desc: count(c.id)]
    )
    |> Repo.all()
  end

  defp get_comments_for_analysis(stream_id, flash_sales) do
    flash_sale_texts = Enum.map(flash_sales, & &1.text)

    # Get unique comments excluding flash sales, including username for AI context
    query =
      from(c in Comment,
        where: c.stream_id == ^stream_id,
        where: c.comment_text not in ^flash_sale_texts,
        distinct: c.comment_text,
        select: %{
          text: c.comment_text,
          username: c.tiktok_nickname,
          at: c.commented_at
        },
        order_by: [asc: c.commented_at]
      )

    all_comments = Repo.all(query)
    sample_comments(all_comments, @max_comments_for_ai)
  end

  defp sample_comments(comments, max) when length(comments) <= max, do: comments

  defp sample_comments(comments, max) do
    # Stratified sampling: beginning, end, and random middle
    count = length(comments)
    first_portion = div(max, 4)
    last_portion = div(max, 4)
    middle_portion = max - first_portion - last_portion

    first = Enum.take(comments, first_portion)
    last = Enum.take(comments, -last_portion)

    middle_start = first_portion
    middle_end = count - last_portion

    middle =
      comments
      |> Enum.slice(middle_start, middle_end - middle_start)
      |> Enum.shuffle()
      |> Enum.take(middle_portion)

    first ++ middle ++ last
  end

  defp generate_sentiment_analysis([]), do: nil

  defp generate_sentiment_analysis(comments) do
    # Format each comment with username for AI context
    formatted_comments =
      comments
      |> Enum.map_join("\n", fn c ->
        username = c.username || "Anonymous"
        "**@#{username}**: #{c.text}"
      end)

    case OpenAIClient.analyze_stream_comments(formatted_comments) do
      {:ok, analysis} ->
        analysis

      {:error, reason} ->
        Logger.warning("AI sentiment analysis failed: #{inspect(reason)}")
        nil
    end
  end

  @doc """
  Sends a complete stream report to Slack, including cover image if available.

  This is the main entry point for sending reports. It:
  1. Uploads the cover image (if available) with the report as initial_comment
  2. Or sends just the Block Kit message if no cover image

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  def send_to_slack(report_data) do
    alias Pavoi.Communications.Slack

    with {:ok, blocks} <- format_slack_blocks(report_data) do
      stream = report_data.stream

      # Try to upload cover image if present (failures are logged but don't block report)
      maybe_upload_cover_image(stream)

      # Always send the message
      Slack.send_message(blocks)
    end
  end

  defp maybe_upload_cover_image(%{cover_image_key: nil}), do: :ok
  defp maybe_upload_cover_image(%{cover_image_key: key, id: stream_id}) do
    alias Pavoi.Communications.Slack
    alias Pavoi.Storage

    with {:ok, image_binary} <- Storage.download(key),
         filename = "stream_#{stream_id}_cover.jpg",
         {:ok, _file_id} <- Slack.upload_image(image_binary, filename, title: "Stream Cover") do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed to upload cover image: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Formats report data into Slack Block Kit blocks.

  Returns `{:ok, blocks}` where blocks is a list of Slack block structures.
  """
  def format_slack_blocks(report_data) do
    blocks =
      List.flatten([
        header_block(report_data.stream),
        divider_block(),
        stats_block(report_data.stats),
        divider_block()
      ])

    blocks =
      if Enum.any?(report_data.top_products) do
        blocks ++ [products_block(report_data.top_products), divider_block()]
      else
        blocks
      end

    blocks =
      if Enum.any?(report_data.flash_sales) do
        blocks ++ [flash_sales_block(report_data.flash_sales), divider_block()]
      else
        blocks
      end

    blocks =
      if report_data.sentiment_analysis do
        blocks ++ [sentiment_block(report_data.sentiment_analysis)]
      else
        blocks
      end

    {:ok, blocks}
  end

  defp header_block(stream) do
    ended_at = format_ended_at(stream.ended_at)
    detail_url = "https://app.pavoi.com/streams?s=#{stream.id}"

    [
      %{
        type: "header",
        text: %{type: "plain_text", text: ":chart_with_upwards_trend: Stream Report", emoji: true}
      },
      %{
        type: "context",
        elements: [
          %{type: "mrkdwn", text: "Ended #{ended_at}  •  <#{detail_url}|View Details>"}
        ]
      }
    ]
  end

  defp format_ended_at(nil), do: "Unknown"

  defp format_ended_at(%DateTime{} = dt) do
    # Convert UTC to PST (UTC-8)
    pst_dt = DateTime.add(dt, -8 * 3600, :second)
    pst_today = DateTime.add(DateTime.utc_now(), -8 * 3600, :second) |> DateTime.to_date()
    date = DateTime.to_date(pst_dt)
    time_str = Calendar.strftime(pst_dt, "%I:%M %p")

    cond do
      date == pst_today ->
        "Today at #{time_str} PST"

      Date.diff(pst_today, date) == 1 ->
        "Yesterday at #{time_str} PST"

      Date.diff(pst_today, date) < 7 ->
        Calendar.strftime(pst_dt, "%A at ") <> "#{time_str} PST"

      true ->
        Calendar.strftime(pst_dt, "%b %d at ") <> "#{time_str} PST"
    end
  end

  defp divider_block, do: %{type: "divider"}

  defp stats_block(stats) do
    # Compact two-column layout with emoji anchors
    text =
      ":clock1: *#{stats.duration_formatted}* duration    :eyes: *#{format_number(stats.peak_viewers)}* peak viewers    :speech_balloon: *#{format_number(stats.total_comments)}* comments\n" <>
        ":heart: *#{format_number(stats.total_likes)}* likes    :gem: *#{format_number(stats.total_gifts_value)}* diamonds"

    %{type: "section", text: %{type: "mrkdwn", text: text}}
  end

  defp products_block(products) do
    lines =
      products
      |> Enum.with_index(1)
      |> Enum.map(fn {p, rank} ->
        # Extract a short, meaningful product name
        name = shorten_product_name(p.product_name || "Unknown")
        "`##{rank}` #{name} — *#{p.comment_count}*"
      end)

    text = ":shopping_bags: *Top Products in Comments*\n" <> Enum.join(lines, "\n")
    %{type: "section", text: %{type: "mrkdwn", text: text}}
  end

  # Extract a short, meaningful product name from verbose Amazon-style titles
  defp shorten_product_name(name) do
    name
    |> String.split(" - ")
    |> List.first()
    |> String.replace(~r/^PAVOI\s+/, "")
    |> String.replace(~r/^14K Gold Plated\s+/, "")
    |> truncate(40)
  end

  defp flash_sales_block(flash_sales) do
    lines =
      flash_sales
      |> Enum.take(3)
      |> Enum.map(fn fs ->
        "\"#{truncate(fs.text, 40)}\" — *#{format_number(fs.count)}x*"
      end)

    text = ":zap: *Flash Sales*\n" <> Enum.join(lines, "\n")

    %{type: "section", text: %{type: "mrkdwn", text: text}}
  end

  defp sentiment_block(analysis) do
    # Convert markdown-style formatting to Slack mrkdwn:
    # - Main bullets: "- " → "• "
    # - Sub-bullets (indented): "  - " → "      ◦ "
    formatted =
      analysis
      |> String.replace(~r/^  - /m, "      ◦ ")
      |> String.replace(~r/^- /m, "• ")

    %{type: "section", text: %{type: "mrkdwn", text: ":bulb: *Insights*\n#{formatted}"}}
  end

  defp format_number(nil), do: "0"

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.to_charlist()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_number(n), do: to_string(n)

  defp truncate(text, max_len) do
    if String.length(text) > max_len do
      String.slice(text, 0, max_len - 3) <> "..."
    else
      text
    end
  end
end
