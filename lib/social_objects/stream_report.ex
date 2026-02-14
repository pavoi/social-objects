defmodule SocialObjects.StreamReport do
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

  alias SocialObjects.AI.OpenAIClient
  alias SocialObjects.Catalog
  alias SocialObjects.Repo
  alias SocialObjects.TiktokLive
  alias SocialObjects.TiktokLive.Comment
  alias SocialObjects.TiktokShop
  alias SocialObjects.TiktokShop.Analytics
  alias SocialObjectsWeb.BrandRoutes

  @flash_sale_threshold 50
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
  def generate(brand_id, stream_id) do
    stream = TiktokLive.get_stream!(brand_id, stream_id)

    # Auto-link to session if not already linked
    _ = TiktokLive.auto_link_stream_to_product_set(brand_id, stream_id)

    # Get basic stats
    stats = get_stats(brand_id, stream)

    # Get product interest (if linked to session)
    products = get_top_products(brand_id, stream_id)

    # Try to fetch product sales data from TikTok Analytics API
    top_selling_products = try_fetch_top_selling_products(brand_id, stream)

    # Detect flash sale comments
    flash_sales = detect_flash_sale_comments(brand_id, stream_id)

    # Use cached sentiment analysis or generate new one
    sentiment = get_or_generate_sentiment(brand_id, stream, flash_sales)

    # Fetch GMV data for the stream time window
    gmv_data = get_gmv_data(brand_id, stream)

    # Get sentiment & category breakdowns for classified comments
    sentiment_breakdown =
      TiktokLive.get_aggregate_sentiment_breakdown(brand_id, stream_id: stream_id)

    category_breakdown = TiktokLive.get_category_breakdown(brand_id, stream_id)
    unique_commenters = TiktokLive.count_unique_commenters(brand_id, stream_id)

    {:ok,
     %{
       stream: stream,
       stats: stats,
       top_products: products,
       top_selling_products: top_selling_products,
       flash_sales: flash_sales,
       sentiment_analysis: sentiment,
       gmv_data: gmv_data,
       sentiment_breakdown: sentiment_breakdown,
       category_breakdown: category_breakdown,
       unique_commenters: unique_commenters
     }}
  end

  defp get_stats(brand_id, stream) do
    duration = calculate_duration(stream.started_at, stream.ended_at)
    comment_count = TiktokLive.count_stream_comments(brand_id, stream.id)

    %{
      duration: duration,
      duration_formatted: format_duration(duration),
      peak_viewers: stream.viewer_count_peak,
      total_likes: stream.total_likes,
      total_gifts_value: stream.total_gifts_value,
      total_comments: comment_count,
      total_follows: stream.total_follows,
      total_shares: stream.total_shares
    }
  end

  defp calculate_duration(started_at, ended_at) do
    cond do
      is_nil(started_at) ->
        0

      is_nil(ended_at) ->
        # Fallback: if ended_at is nil but stream is being reported, use current time
        # This shouldn't normally happen (StreamReportWorker guards against it), but
        # provides a reasonable fallback rather than showing "< 1m" for long streams
        Logger.warning("Calculating duration with nil ended_at, using current time as fallback")
        DateTime.diff(DateTime.utc_now(), started_at, :second)

      true ->
        DateTime.diff(ended_at, started_at, :second)
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

  defp get_top_products(brand_id, stream_id) do
    case TiktokLive.get_linked_product_sets(brand_id, stream_id) do
      [session | _] ->
        TiktokLive.get_product_interest_summary(brand_id, stream_id, session.id)
        |> Enum.take(5)

      [] ->
        []
    end
  end

  # Try to fetch product sales data from TikTok Analytics API
  # This may not be available immediately after stream ends
  defp try_fetch_top_selling_products(brand_id, stream) do
    case Analytics.try_fetch_product_performance_for_stream(brand_id, stream) do
      {:ok, %{"products" => products}} when is_list(products) and products != [] ->
        # Return top 5 products by GMV
        products
        |> Enum.sort_by(& &1["gmv_cents"], :desc)
        |> Enum.take(5)

      {:ok, _} ->
        Logger.debug("No product performance data available for stream #{stream.id}")
        nil

      {:error, :no_match} ->
        Logger.debug(
          "No matching TikTok session found for stream #{stream.id} - data may not be available yet"
        )

        nil

      {:error, reason} ->
        Logger.debug(
          "Failed to fetch product performance for stream #{stream.id}: #{inspect(reason)}"
        )

        nil
    end
  end

  defp get_gmv_data(_brand_id, %{started_at: nil}), do: nil
  defp get_gmv_data(_brand_id, %{ended_at: nil}), do: nil

  defp get_gmv_data(brand_id, stream) do
    case TiktokShop.fetch_orders_in_range(brand_id, stream.started_at, stream.ended_at) do
      {:ok, orders} ->
        build_gmv_summary(orders)

      {:error, reason} ->
        Logger.warning("Failed to fetch GMV data: #{inspect(reason)}")
        nil
    end
  end

  defp build_gmv_summary(orders) do
    hourly = TiktokShop.calculate_hourly_gmv(orders)

    %{
      hourly: hourly,
      total_gmv_cents: sum_field(hourly, :gmv_cents),
      total_orders: sum_field(hourly, :order_count)
    }
  end

  defp sum_field(list, field) do
    Enum.reduce(list, 0, fn item, acc -> acc + Map.get(item, field, 0) end)
  end

  @doc """
  Detects flash sale comments - those appearing many times with identical text.

  Returns a list of `%{text: string, count: integer}` sorted by count descending.
  """
  def detect_flash_sale_comments(brand_id, stream_id) do
    from(c in Comment,
      where: c.brand_id == ^brand_id and c.stream_id == ^stream_id,
      group_by: c.comment_text,
      having: count(c.id) >= ^@flash_sale_threshold,
      select: %{text: c.comment_text, count: count(c.id)},
      order_by: [desc: count(c.id)]
    )
    |> Repo.all()
  end

  defp get_comments_for_analysis(brand_id, stream_id, flash_sales) do
    flash_sale_texts = Enum.map(flash_sales, & &1.text)

    # Get unique comments excluding flash sales, including username for AI context
    query =
      from(c in Comment,
        where: c.brand_id == ^brand_id and c.stream_id == ^stream_id,
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

    Logger.info(
      "Stream #{stream_id}: found #{length(all_comments)} unique comments " <>
        "(excluded #{length(flash_sale_texts)} flash sale patterns)"
    )

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

  # Use cached sentiment analysis if available, otherwise generate and cache it
  defp get_or_generate_sentiment(_brand_id, %{sentiment_analysis: cached} = _stream, _flash_sales)
       when is_binary(cached) and cached != "" do
    Logger.info("Using cached sentiment analysis")
    cached
  end

  defp get_or_generate_sentiment(brand_id, stream, flash_sales) do
    comments = get_comments_for_analysis(brand_id, stream.id, flash_sales)
    sentiment = generate_sentiment_analysis(comments)

    # Cache the sentiment analysis on the stream
    if sentiment do
      save_sentiment_analysis(brand_id, stream.id, sentiment)
    end

    sentiment
  end

  defp save_sentiment_analysis(brand_id, stream_id, sentiment) do
    alias SocialObjects.TiktokLive.Stream

    from(s in Stream, where: s.id == ^stream_id)
    |> where([s], s.brand_id == ^brand_id)
    |> Repo.update_all(set: [sentiment_analysis: sentiment])
  end

  defp generate_sentiment_analysis([]) do
    Logger.warning("Sentiment analysis skipped: no comments to analyze")
    nil
  end

  defp generate_sentiment_analysis(comments) do
    Logger.info("Generating sentiment analysis for #{length(comments)} comments")

    # Format each comment with username for AI context
    formatted_comments =
      comments
      |> Enum.map_join("\n", fn c ->
        username = c.username || "Anonymous"
        "**@#{username}**: #{c.text}"
      end)

    case OpenAIClient.analyze_stream_comments(formatted_comments) do
      {:ok, analysis} ->
        Logger.info("Sentiment analysis completed successfully")
        analysis

      {:error, reason} ->
        Logger.warning("AI sentiment analysis failed: #{inspect(reason)}")
        nil
    end
  end

  @doc """
  Sends a complete stream report to Slack, including cover image if available.

  This is the main entry point for sending reports. It:
  1. Includes the cover image in the Block Kit message if available
  2. Otherwise sends just the Block Kit message

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  def send_to_slack(report_data) do
    alias SocialObjects.Communications.Slack

    with {:ok, blocks} <- format_slack_blocks(report_data) do
      # Always send the message
      Slack.send_message(blocks, brand_id: report_data.stream.brand_id)
    end
  end

  @doc """
  Formats report data into Slack Block Kit blocks.

  Returns `{:ok, blocks}` where blocks is a list of Slack block structures.
  """
  def format_slack_blocks(report_data) do
    base_blocks =
      List.flatten([
        header_block(report_data.stream),
        cover_image_block(report_data.stream),
        divider_block(),
        stats_block(report_data.stats, report_data.unique_commenters),
        divider_block()
      ])

    blocks =
      base_blocks
      |> maybe_add_gmv_section(report_data)
      |> maybe_add_products_section(report_data)
      |> maybe_add_top_selling_section(report_data)
      |> maybe_add_flash_sales_section(report_data)
      |> maybe_add_sentiment_stats_section(report_data)
      |> maybe_add_category_section(report_data)
      |> maybe_add_insights_section(report_data)

    {:ok, blocks}
  end

  defp maybe_add_gmv_section(blocks, %{gmv_data: %{total_orders: orders} = gmv_data})
       when orders > 0 do
    blocks ++ [gmv_block(gmv_data), divider_block()]
  end

  defp maybe_add_gmv_section(blocks, _report_data), do: blocks

  defp maybe_add_products_section(blocks, %{stream: stream, top_products: products})
       when products != [] do
    blocks ++ [products_block(stream, products), divider_block()]
  end

  defp maybe_add_products_section(blocks, _report_data), do: blocks

  defp maybe_add_top_selling_section(blocks, %{top_selling_products: products})
       when is_list(products) and products != [] do
    blocks ++ [top_selling_products_block(products), divider_block()]
  end

  defp maybe_add_top_selling_section(blocks, _report_data), do: blocks

  defp maybe_add_flash_sales_section(blocks, %{flash_sales: flash_sales})
       when flash_sales != [] do
    blocks ++ [flash_sales_block(flash_sales), divider_block()]
  end

  defp maybe_add_flash_sales_section(blocks, _report_data), do: blocks

  defp maybe_add_sentiment_stats_section(blocks, %{sentiment_breakdown: breakdown} = report_data)
       when not is_nil(breakdown) do
    blocks ++ [sentiment_stats_block(report_data), divider_block()]
  end

  defp maybe_add_sentiment_stats_section(blocks, _report_data), do: blocks

  defp maybe_add_category_section(blocks, %{category_breakdown: categories})
       when is_list(categories) and categories != [] do
    blocks ++ [category_breakdown_block(categories), divider_block()]
  end

  defp maybe_add_category_section(blocks, _report_data), do: blocks

  defp maybe_add_insights_section(blocks, %{sentiment_analysis: analysis})
       when not is_nil(analysis) do
    blocks ++ [sentiment_block(analysis)]
  end

  defp maybe_add_insights_section(blocks, _report_data), do: blocks

  defp header_block(stream) do
    ended_at = format_ended_at(stream.ended_at)

    brand =
      if Ecto.assoc_loaded?(stream.brand) do
        stream.brand
      else
        Catalog.get_brand!(stream.brand_id)
      end

    detail_url = BrandRoutes.brand_url(brand, "/streams?s=#{stream.id}")
    analytics_url = BrandRoutes.brand_url(brand, "/streams?as=#{stream.id}&pt=analytics")

    [
      %{
        type: "header",
        text: %{type: "plain_text", text: ":chart_with_upwards_trend: Stream Report", emoji: true}
      },
      %{
        type: "context",
        elements: [
          %{
            type: "mrkdwn",
            text:
              "Ended #{ended_at}  •  <#{detail_url}|View Details>  •  <#{analytics_url}|Analytics>"
          }
        ]
      }
    ]
  end

  defp cover_image_block(stream) do
    case SocialObjects.TiktokLive.Stream.cover_image_url(stream) do
      nil ->
        []

      url ->
        [
          %{
            type: "image",
            image_url: url,
            alt_text: "Stream cover image"
          }
        ]
    end
  end

  defp format_ended_at(nil), do: "Unknown"

  defp format_ended_at(%DateTime{} = dt) do
    {offset, tz_abbr} = pacific_offset(dt)
    local_dt = DateTime.add(dt, offset, :second)
    local_now = DateTime.add(DateTime.utc_now(), offset, :second)
    local_today = DateTime.to_date(local_now)
    date = DateTime.to_date(local_dt)
    time_str = Calendar.strftime(local_dt, "%I:%M %p")

    cond do
      date == local_today ->
        "Today at #{time_str} #{tz_abbr}"

      Date.diff(local_today, date) == 1 ->
        "Yesterday at #{time_str} #{tz_abbr}"

      Date.diff(local_today, date) < 7 ->
        Calendar.strftime(local_dt, "%A at ") <> "#{time_str} #{tz_abbr}"

      true ->
        Calendar.strftime(local_dt, "%b %d at ") <> "#{time_str} #{tz_abbr}"
    end
  end

  defp divider_block, do: %{type: "divider"}

  defp stats_block(stats, unique_commenters) do
    # Compact two-column layout with emoji anchors
    text =
      ":clock1: *#{stats.duration_formatted}* duration    :eyes: *#{format_number(stats.peak_viewers)}* peak viewers    :speech_balloon: *#{format_number(stats.total_comments)}* comments\n" <>
        ":heart: *#{format_number(stats.total_likes)}* likes    :gem: *#{format_number(stats.total_gifts_value)}* diamonds    :busts_in_silhouette: *#{format_number(unique_commenters || 0)}* unique commenters\n" <>
        ":heavy_plus_sign: *#{format_number(stats.total_follows)}* follows    :arrow_right: *#{format_number(stats.total_shares)}* shares"

    %{type: "section", text: %{type: "mrkdwn", text: text}}
  end

  defp gmv_block(gmv_data) do
    total_gmv = format_money(gmv_data.total_gmv_cents)
    total_orders = gmv_data.total_orders
    duration_hours = length(gmv_data.hourly)

    gmv_per_hour =
      if duration_hours > 0 do
        format_money(div(gmv_data.total_gmv_cents, duration_hours))
      else
        "$0"
      end

    # Build hourly breakdown
    hourly_lines =
      Enum.map_join(gmv_data.hourly, "\n", fn h ->
        hour_str = format_hour_pst(h.hour)
        "#{hour_str}: *#{format_money(h.gmv_cents)}* (#{h.order_count} orders)"
      end)

    text =
      ":moneybag: *GMV During Stream* _(correlation, not attribution)_\n" <>
        "*#{total_gmv}* total  •  *#{total_orders}* orders  •  *#{gmv_per_hour}/hr* avg\n\n" <>
        "_Hourly breakdown:_\n#{hourly_lines}"

    %{type: "section", text: %{type: "mrkdwn", text: text}}
  end

  defp format_hour_pst(hour) do
    {offset, _tz_abbr} = pacific_offset(hour)
    local_hour = DateTime.add(hour, offset, :second)
    Calendar.strftime(local_hour, "%I %p")
  end

  defp format_money(cents) when is_integer(cents) do
    dollars = round(cents / 100)

    formatted =
      dollars
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

    "$#{formatted}"
  end

  defp format_money(_), do: "$0"

  defp products_block(stream, products) do
    brand = stream.brand || Catalog.get_brand!(stream.brand_id)

    lines =
      products
      |> Enum.with_index(1)
      |> Enum.map(fn {product, rank} ->
        # Extract a short, meaningful product name
        name = shorten_product_name(product.product_name || "Unknown")
        link = product_more_info_link(brand, product.product_id)
        "`##{rank}` #{name} — *#{product.comment_count}*#{link}"
      end)

    text = ":shopping_bags: *Top Products in Comments*\n" <> Enum.join(lines, "\n")
    %{type: "section", text: %{type: "mrkdwn", text: text}}
  end

  defp product_more_info_link(_brand, nil), do: ""

  defp product_more_info_link(brand, product_id) do
    url = BrandRoutes.brand_url(brand, "/products?pt=products&p=#{product_id}")
    " (<#{url}|more info>)"
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

  defp top_selling_products_block(products) do
    lines =
      products
      |> Enum.with_index(1)
      |> Enum.map(fn {product, rank} ->
        name = shorten_product_name(product["product_name"] || "Unknown")
        gmv = format_money(product["gmv_cents"] || 0)
        items = product["items_sold"] || 0
        "`##{rank}` #{name} — *#{gmv}* (#{items} sold)"
      end)

    text = ":chart_with_upwards_trend: *Top Selling Products*\n" <> Enum.join(lines, "\n")
    %{type: "section", text: %{type: "mrkdwn", text: text}}
  end

  defp flash_sales_block(flash_sales) do
    lines =
      flash_sales
      |> Enum.take(3)
      |> Enum.map(fn fs ->
        "\"#{truncate(fs.text, 40)}\" (#{format_number(fs.count)} comments)"
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

  defp sentiment_stats_block(report_data) do
    breakdown = report_data.sentiment_breakdown

    # Build combined emoji bar showing all sentiments proportionally
    sentiment_bar =
      build_combined_sentiment_bar(
        breakdown.positive.percent,
        breakdown.neutral.percent,
        breakdown.negative.percent
      )

    text =
      ":bar_chart: *Comment Sentiment*\n" <>
        "#{breakdown.positive.percent}% Positive  |  #{breakdown.neutral.percent}% Neutral  |  #{breakdown.negative.percent}% Negative\n" <>
        "#{sentiment_bar}"

    %{type: "section", text: %{type: "mrkdwn", text: text}}
  end

  defp build_combined_sentiment_bar(pos_pct, _neu_pct, neg_pct) do
    # Scale to 10 segments total
    pos_count = round(pos_pct / 10)
    neg_count = round(neg_pct / 10)
    # Neutral fills the remainder to ensure exactly 10 segments
    neu_count = 10 - pos_count - neg_count

    String.duplicate("🟢", pos_count) <>
      String.duplicate("⚪", neu_count) <>
      String.duplicate("🔴", neg_count)
  end

  defp category_breakdown_block(categories) do
    category_labels = %{
      praise_compliment: "Praise",
      question_confusion: "Questions",
      product_request: "Product Requests",
      concern_complaint: "Concerns",
      technical_issue: "Tech Issues",
      general: "General"
    }

    # Format each category with count and percentage
    formatted =
      categories
      |> Enum.map(fn c ->
        label = Map.get(category_labels, c.category, "Other")
        "#{label} — *#{c.count}* (#{c.percent}%)"
      end)
      |> Enum.chunk_every(3)
      |> Enum.map_join("\n", &Enum.join(&1, "  |  "))

    text = ":speech_balloon: *Comment Categories*\n#{formatted}"
    %{type: "section", text: %{type: "mrkdwn", text: text}}
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

  # Returns {utc_offset_seconds, abbreviation} for US Pacific time,
  # accounting for daylight saving time (PDT: Mar-Nov, PST: Nov-Mar).
  # DST starts second Sunday of March, ends first Sunday of November.
  defp pacific_offset(%DateTime{} = dt) do
    date = DateTime.to_date(dt)

    if in_pacific_dst?(date) do
      {-7 * 3600, "PDT"}
    else
      {-8 * 3600, "PST"}
    end
  end

  defp in_pacific_dst?(date) do
    year = date.year

    # Second Sunday of March (DST starts at 2:00 AM local, but we approximate by date)
    dst_start = second_sunday_of(year, 3)
    # First Sunday of November (DST ends at 2:00 AM local)
    dst_end = first_sunday_of(year, 11)

    Date.compare(date, dst_start) != :lt and Date.compare(date, dst_end) == :lt
  end

  defp second_sunday_of(year, month) do
    # First day of month
    {:ok, first} = Date.new(year, month, 1)
    # Day of week (1=Monday, 7=Sunday)
    dow = Date.day_of_week(first)
    # Days until first Sunday
    days_to_sunday = rem(7 - dow, 7)
    # Second Sunday = first Sunday + 7
    Date.add(first, days_to_sunday + 7)
  end

  defp first_sunday_of(year, month) do
    {:ok, first} = Date.new(year, month, 1)
    dow = Date.day_of_week(first)
    days_to_sunday = rem(7 - dow, 7)
    Date.add(first, days_to_sunday)
  end
end
