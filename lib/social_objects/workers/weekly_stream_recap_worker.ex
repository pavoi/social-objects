defmodule SocialObjects.Workers.WeeklyStreamRecapWorker do
  @moduledoc """
  Oban worker that sends a weekly Slack recap of stream performance.

  Runs every Monday at 9 AM PST (5 PM UTC) and aggregates all streams
  from the previous week (Monday 00:00 PST to Sunday 11:59 PM PST).

  This timing ensures all streams have 2+ days for TikTok Analytics data
  to finalize before the recap is sent.

  ## Slack Message Contents

  - Stream count + customer count + sync status
  - GMV: 24h attributed (primary), live session GMV (secondary)
  - Engagement: Avg view duration, product impressions, product clicks, CTR
  - All streams for the week listed by GMV (sorted descending)
  """

  use Oban.Worker, queue: :slack, max_attempts: 3

  require Logger

  import Ecto.Query

  alias SocialObjects.Catalog
  alias SocialObjects.Communications.Slack
  alias SocialObjects.Repo
  alias SocialObjects.Settings
  alias SocialObjects.TiktokLive.Stream
  alias SocialObjectsWeb.BrandRoutes

  # PST is UTC-8
  @pst_offset_hours -8

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"brand_id" => brand_id}}) do
    _ = broadcast(brand_id, {:weekly_recap_sync_started})
    {start_time, end_time} = get_week_time_range()
    streams = get_week_streams(brand_id, start_time, end_time)

    if Enum.empty?(streams) do
      Logger.info("No streams for weekly recap (brand #{brand_id})")

      _ =
        broadcast(
          brand_id,
          {:weekly_recap_sync_completed, %{streams_count: 0, status: :no_streams}}
        )

      :ok
    else
      case send_weekly_recap(brand_id, streams, start_time, end_time) do
        :ok ->
          _ =
            broadcast(brand_id, {:weekly_recap_sync_completed, %{streams_count: length(streams)}})

          :ok

        {:cancel, reason} ->
          _ = broadcast(brand_id, {:weekly_recap_sync_failed, reason})
          {:cancel, reason}

        {:error, reason} ->
          _ = broadcast(brand_id, {:weekly_recap_sync_failed, reason})
          {:error, reason}
      end
    end
  end

  defp get_week_time_range do
    now_utc = DateTime.utc_now()
    now_pst = DateTime.add(now_utc, @pst_offset_hours * 3600, :second)
    today = DateTime.to_date(now_pst)

    # Find the PREVIOUS week's Monday (7-13 days ago depending on current day)
    # If today is Monday, we want last Monday (7 days ago)
    days_since_monday = Date.day_of_week(today) - 1
    this_monday = Date.add(today, -days_since_monday)
    last_monday = Date.add(this_monday, -7)
    last_sunday = Date.add(last_monday, 6)

    # Start: Previous Monday at 00:00 PST
    start_time_pst =
      DateTime.new!(last_monday, ~T[00:00:00], "Etc/UTC")
      |> DateTime.add(@pst_offset_hours * 3600, :second)

    start_time_utc = DateTime.add(start_time_pst, -@pst_offset_hours * 3600, :second)

    # End: Previous Sunday at 23:59:59 PST
    end_time_pst =
      DateTime.new!(last_sunday, ~T[23:59:59], "Etc/UTC")
      |> DateTime.add(@pst_offset_hours * 3600, :second)

    end_time_utc = DateTime.add(end_time_pst, -@pst_offset_hours * 3600, :second)

    {start_time_utc, end_time_utc}
  end

  defp get_week_streams(brand_id, start_time, end_time) do
    from(s in Stream,
      where: s.brand_id == ^brand_id,
      where: s.status == :ended,
      where: s.started_at >= ^start_time,
      where: s.started_at <= ^end_time,
      order_by: [desc: coalesce(s.gmv_24h_cents, coalesce(s.official_gmv_cents, 0))]
    )
    |> Repo.all()
  end

  defp send_weekly_recap(brand_id, streams, start_time, end_time) do
    blocks = build_slack_blocks(brand_id, streams, start_time, end_time)

    case Slack.send_message(blocks, brand_id: brand_id, text: "Weekly Stream Recap") do
      {:ok, :sent} ->
        _ = Settings.update_weekly_recap_last_sent_at(brand_id)
        Logger.info("Weekly stream recap sent for brand #{brand_id}")
        :ok

      {:error, "Slack not configured" <> _} ->
        Logger.warning("Skipping weekly recap - Slack not configured")
        {:cancel, :slack_not_configured}

      {:error, reason} ->
        Logger.error("Failed to send weekly recap: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_slack_blocks(brand_id, streams, start_time, end_time) do
    brand = Catalog.get_brand!(brand_id)

    List.flatten([
      header_block(start_time, end_time),
      divider_block(),
      summary_block(streams),
      divider_block(),
      gmv_block(streams),
      divider_block(),
      engagement_block(streams),
      divider_block(),
      streams_list_block(brand, streams)
    ])
  end

  defp header_block(start_time, end_time) do
    start_str = format_date_pst(start_time)
    end_str = format_date_pst(end_time)

    [
      %{
        type: "header",
        text: %{type: "plain_text", text: ":calendar: Weekly Stream Recap", emoji: true}
      },
      %{
        type: "context",
        elements: [
          %{type: "mrkdwn", text: "#{start_str} — #{end_str} (PST)"}
        ]
      }
    ]
  end

  defp format_date_pst(datetime) do
    pst = DateTime.add(datetime, @pst_offset_hours * 3600, :second)
    Calendar.strftime(pst, "%b %d")
  end

  defp broadcast(brand_id, message) do
    Phoenix.PubSub.broadcast(
      SocialObjects.PubSub,
      "weekly_recap:sync:#{brand_id}",
      message
    )
  end

  defp summary_block(streams) do
    total_streams = length(streams)

    total_customers =
      streams
      |> Enum.map(& &1.unique_customers)
      |> Enum.reject(&is_nil/1)
      |> Enum.sum()

    text =
      ":tv: *#{total_streams}* streams    " <>
        ":bust_in_silhouette: *#{format_number(total_customers)}* customers"

    %{type: "section", text: %{type: "mrkdwn", text: text}}
  end

  defp gmv_block(streams) do
    # Live Session GMV - sales during the actual stream
    live_gmv_cents =
      streams
      |> Enum.map(& &1.official_gmv_cents)
      |> Enum.reject(&is_nil/1)
      |> Enum.sum()

    # 24h Attributed GMV - sales attributed to stream within 24 hours
    gmv_24h_cents =
      streams
      |> Enum.map(& &1.gmv_24h_cents)
      |> Enum.reject(&is_nil/1)
      |> Enum.sum()

    # Total items sold
    items_sold =
      streams
      |> Enum.map(& &1.items_sold)
      |> Enum.reject(&is_nil/1)
      |> Enum.sum()

    text =
      ":moneybag: *GMV*\n" <>
        "*#{format_money(gmv_24h_cents)}* total _(24h attributed)_\n" <>
        "*#{format_money(live_gmv_cents)}* during streams  •  *#{format_number(items_sold)}* items sold"

    %{type: "section", text: %{type: "mrkdwn", text: text}}
  end

  defp engagement_block(streams) do
    # Average view duration (only from synced streams)
    durations =
      streams
      |> Enum.map(& &1.avg_view_duration_seconds)
      |> Enum.reject(&is_nil/1)

    avg_duration =
      if Enum.empty?(durations) do
        nil
      else
        div(Enum.sum(durations), length(durations))
      end

    # Total product metrics
    impressions =
      streams
      |> Enum.map(& &1.product_impressions)
      |> Enum.reject(&is_nil/1)
      |> Enum.sum()

    clicks =
      streams
      |> Enum.map(& &1.product_clicks)
      |> Enum.reject(&is_nil/1)
      |> Enum.sum()

    # Calculate CTR
    ctr = if impressions > 0, do: Float.round(clicks / impressions * 100, 2), else: nil

    duration_str = if avg_duration, do: format_duration(avg_duration), else: "—"
    ctr_str = if ctr, do: "#{ctr}%", else: "—"

    text =
      ":chart_with_upwards_trend: *Engagement*\n" <>
        "*Avg View Duration:* #{duration_str}    " <>
        "*Product Impressions:* #{format_number(impressions)}\n" <>
        "*Product Clicks:* #{format_number(clicks)}    " <>
        "*CTR:* #{ctr_str}"

    %{type: "section", text: %{type: "mrkdwn", text: text}}
  end

  defp streams_list_block(brand, streams) do
    # List all streams sorted by 24h attributed GMV (already sorted from query)
    lines =
      streams
      |> Enum.with_index(1)
      |> Enum.map(fn {stream, rank} ->
        gmv = stream.gmv_24h_cents || stream.official_gmv_cents || 0
        date = format_stream_date(stream.started_at)
        detail_url = BrandRoutes.brand_url(brand, "/streams?s=#{stream.id}")

        "`#{rank}.` @#{stream.unique_id} (#{date}) — *#{format_money(gmv)}* (<#{detail_url}|more info>)"
      end)
      |> Enum.take(15)

    more_count = max(0, length(streams) - 15)
    suffix = if more_count > 0, do: "\n_...and #{more_count} more_", else: ""

    text = ":tv: *Streams by 24h GMV*\n" <> Enum.join(lines, "\n") <> suffix

    %{type: "section", text: %{type: "mrkdwn", text: text}}
  end

  defp format_stream_date(datetime) do
    pst = DateTime.add(datetime, @pst_offset_hours * 3600, :second)
    Calendar.strftime(pst, "%a %I:%M %p")
  end

  defp divider_block, do: %{type: "divider"}

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

  defp format_money(nil), do: "$0"
  defp format_money(0), do: "$0"

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

  defp format_duration(seconds) do
    minutes = div(seconds, 60)
    remaining_seconds = rem(seconds, 60)

    if minutes > 0 do
      "#{minutes}m #{remaining_seconds}s"
    else
      "#{remaining_seconds}s"
    end
  end
end
