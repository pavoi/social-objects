defmodule Pavoi.Workers.WeeklyStreamRecapWorker do
  @moduledoc """
  Oban worker that sends a weekly Slack recap of stream performance.

  Runs every Friday at 3 PM PST (11 PM UTC) and aggregates all streams
  from Monday 00:00 PST to Friday 3 PM PST.

  ## Slack Message Contents

  - Stream count + customer count + sync status
  - GMV comparison: Official vs Order-based (with % difference indicator)
  - 24h attributed GMV total
  - Engagement: Avg view duration, product impressions, product clicks, CTR
  - All streams for the week listed by GMV (sorted descending)
  """

  use Oban.Worker, queue: :slack, max_attempts: 3

  require Logger

  import Ecto.Query

  alias Pavoi.Communications.Slack
  alias Pavoi.Repo
  alias Pavoi.TiktokLive.Stream

  # PST is UTC-8
  @pst_offset_hours -8

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"brand_id" => brand_id}}) do
    {start_time, end_time} = get_week_time_range()
    streams = get_week_streams(brand_id, start_time, end_time)

    if Enum.empty?(streams) do
      Logger.info("No streams for weekly recap (brand #{brand_id})")
      :ok
    else
      send_weekly_recap(brand_id, streams, start_time, end_time)
    end
  end

  defp get_week_time_range do
    now_utc = DateTime.utc_now()
    now_pst = DateTime.add(now_utc, @pst_offset_hours * 3600, :second)

    # Friday 3 PM PST = end of range (current time)
    end_time_pst = now_pst
    end_time_utc = DateTime.add(end_time_pst, -@pst_offset_hours * 3600, :second)

    # Find the previous Monday at 00:00 PST
    days_since_monday = Date.day_of_week(DateTime.to_date(now_pst)) - 1
    monday_date = Date.add(DateTime.to_date(now_pst), -days_since_monday)

    start_time_pst =
      DateTime.new!(monday_date, ~T[00:00:00], "Etc/UTC")
      |> DateTime.add(@pst_offset_hours * 3600, :second)

    start_time_utc = DateTime.add(start_time_pst, -@pst_offset_hours * 3600, :second)

    {start_time_utc, end_time_utc}
  end

  defp get_week_streams(brand_id, start_time, end_time) do
    from(s in Stream,
      where: s.brand_id == ^brand_id,
      where: s.status == :ended,
      where: s.started_at >= ^start_time,
      where: s.started_at <= ^end_time,
      order_by: [desc: coalesce(s.official_gmv_cents, coalesce(s.gmv_cents, 0))]
    )
    |> Repo.all()
  end

  defp send_weekly_recap(brand_id, streams, start_time, end_time) do
    blocks = build_slack_blocks(streams, start_time, end_time)

    case Slack.send_message(blocks, brand_id: brand_id, text: "Weekly Stream Recap") do
      {:ok, :sent} ->
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

  defp build_slack_blocks(streams, start_time, end_time) do
    List.flatten([
      header_block(start_time, end_time),
      divider_block(),
      summary_block(streams),
      divider_block(),
      gmv_block(streams),
      divider_block(),
      engagement_block(streams),
      divider_block(),
      streams_list_block(streams)
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

  defp summary_block(streams) do
    total_streams = length(streams)
    synced_count = Enum.count(streams, &(&1.analytics_synced_at != nil))
    pending_count = total_streams - synced_count

    total_customers =
      streams
      |> Enum.map(& &1.unique_customers)
      |> Enum.reject(&is_nil/1)
      |> Enum.sum()

    sync_status =
      cond do
        pending_count == 0 -> ":white_check_mark: All synced"
        pending_count == total_streams -> ":hourglass: None synced yet"
        true -> ":hourglass: #{synced_count}/#{total_streams} synced"
      end

    text =
      ":tv: *#{total_streams}* streams    " <>
        ":bust_in_silhouette: *#{format_number(total_customers)}* customers    " <>
        "#{sync_status}"

    %{type: "section", text: %{type: "mrkdwn", text: text}}
  end

  defp gmv_block(streams) do
    # Order-based GMV (from BigQuery orders during stream)
    order_gmv_cents =
      streams
      |> Enum.map(& &1.gmv_cents)
      |> Enum.reject(&is_nil/1)
      |> Enum.sum()

    # Official GMV from TikTok Analytics API
    official_gmv_cents =
      streams
      |> Enum.map(& &1.official_gmv_cents)
      |> Enum.reject(&is_nil/1)
      |> Enum.sum()

    # 24h attributed GMV
    gmv_24h_cents =
      streams
      |> Enum.map(& &1.gmv_24h_cents)
      |> Enum.reject(&is_nil/1)
      |> Enum.sum()

    # Calculate difference indicator
    diff_indicator = gmv_diff_indicator(order_gmv_cents, official_gmv_cents)

    text =
      ":moneybag: *GMV Summary*\n" <>
        "*Official (TikTok):* #{format_money(official_gmv_cents)}\n" <>
        "*Order-based:* #{format_money(order_gmv_cents)} #{diff_indicator}\n" <>
        "*24h Attributed:* #{format_money(gmv_24h_cents)}"

    %{type: "section", text: %{type: "mrkdwn", text: text}}
  end

  defp gmv_diff_indicator(order_gmv, official_gmv) when order_gmv > 0 and official_gmv > 0 do
    diff_percent = (official_gmv - order_gmv) / order_gmv * 100

    cond do
      abs(diff_percent) < 5 -> ""
      diff_percent > 0 -> "_(#{Float.round(diff_percent, 1)}% higher official)_"
      true -> "_(#{Float.round(abs(diff_percent), 1)}% lower official)_"
    end
  end

  defp gmv_diff_indicator(_, _), do: ""

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

  defp streams_list_block(streams) do
    # List all streams sorted by GMV (already sorted from query)
    lines =
      streams
      |> Enum.with_index(1)
      |> Enum.map(fn {stream, rank} ->
        gmv = stream.official_gmv_cents || stream.gmv_cents || 0
        date = format_stream_date(stream.started_at)
        sync_icon = if stream.analytics_synced_at, do: ":white_check_mark:", else: ":hourglass:"

        "`#{rank}.` @#{stream.unique_id} (#{date}) — *#{format_money(gmv)}* #{sync_icon}"
      end)
      |> Enum.take(15)

    more_count = max(0, length(streams) - 15)
    suffix = if more_count > 0, do: "\n_...and #{more_count} more_", else: ""

    text = ":tv: *Streams by GMV*\n" <> Enum.join(lines, "\n") <> suffix

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
