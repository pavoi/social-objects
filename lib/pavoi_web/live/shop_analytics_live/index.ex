defmodule PavoiWeb.ShopAnalyticsLive.Index do
  @moduledoc """
  LiveView for Shop Performance Analytics dashboard.

  Displays key metrics from TikTok Shop Analytics API:
  - GMV, Orders, Items Sold, Conversion Rate
  - Channel breakdown (LIVE vs VIDEO vs PRODUCT_CARD)
  - Hourly performance trends
  """
  use PavoiWeb, :live_view

  on_mount {PavoiWeb.NavHooks, :set_current_page}

  alias Pavoi.TiktokShop.Analytics
  alias Pavoi.TiktokShop.AnalyticsCache
  alias PavoiWeb.BrandRoutes

  import PavoiWeb.ShopAnalyticsComponents

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:date_preset, "30d")
      |> assign(:loading, true)
      |> assign(:error, nil)
      |> assign(:error_type, nil)
      |> assign(:current_metrics, nil)
      |> assign(:previous_metrics, nil)
      |> assign(:deltas, nil)
      |> assign(:channel_chart_json, nil)
      |> assign(:hourly_chart_json, nil)
      |> assign(:analytics_refreshing, false)
      |> assign(:analytics_last_fetch_at, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    preset = params["preset"] || "30d"

    socket =
      socket
      |> assign(:date_preset, preset)
      |> load_analytics_data()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_date", %{"preset" => preset}, socket) do
    path = analytics_path(socket, %{preset: preset})
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("retry_load", _params, socket) do
    {:noreply, load_analytics_data(socket)}
  end

  @impl true
  def handle_event("refresh_analytics", _params, socket) do
    brand_id = socket.assigns.current_brand.id

    # Invalidate cache for this brand
    AnalyticsCache.invalidate_brand(brand_id)

    # Reload data
    socket =
      socket
      |> assign(:analytics_refreshing, true)
      |> load_analytics_data()
      |> assign(:analytics_refreshing, false)
      |> assign(:analytics_last_fetch_at, DateTime.utc_now())

    {:noreply, socket}
  end

  # Data Loading

  defp load_analytics_data(socket) do
    brand_id = socket.assigns.current_brand.id
    preset = socket.assigns.date_preset

    {start_date, end_date} = calculate_date_range(preset)
    {prev_start, prev_end} = previous_period(start_date, end_date)

    socket = assign(socket, :loading, true)

    # Fetch current period data (cached)
    current_result =
      AnalyticsCache.fetch({brand_id, :shop_performance, preset}, fn ->
        Analytics.get_shop_performance(brand_id,
          start_date_ge: Date.to_iso8601(start_date),
          end_date_lt: Date.to_iso8601(end_date),
          currency: "USD"
        )
      end)

    # Fetch previous period data for delta calculation (cached)
    previous_result =
      AnalyticsCache.fetch({brand_id, :shop_performance_prev, preset}, fn ->
        Analytics.get_shop_performance(brand_id,
          start_date_ge: Date.to_iso8601(prev_start),
          end_date_lt: Date.to_iso8601(prev_end),
          currency: "USD"
        )
      end)

    # Fetch hourly data for the most recent day (cached)
    yesterday = Date.add(Date.utc_today(), -1)

    hourly_result =
      AnalyticsCache.fetch({brand_id, :hourly_performance, Date.to_iso8601(yesterday)}, fn ->
        Analytics.get_shop_performance_per_hour(brand_id,
          date: Date.to_iso8601(yesterday),
          currency: "USD"
        )
      end)

    case {current_result, previous_result} do
      {{:ok, current_data}, {:ok, previous_data}} ->
        current_metrics = transform_metrics(current_data)
        previous_metrics = transform_metrics(previous_data)
        deltas = calculate_deltas(current_metrics, previous_metrics)
        channel_chart_json = build_channel_chart_json(current_metrics)

        hourly_chart_json =
          case hourly_result do
            {:ok, hourly_data} -> build_hourly_chart_json(hourly_data)
            _ -> Jason.encode!(%{labels: [], datasets: []})
          end

        socket
        |> assign(:loading, false)
        |> assign(:error, nil)
        |> assign(:error_type, nil)
        |> assign(:current_metrics, current_metrics)
        |> assign(:previous_metrics, previous_metrics)
        |> assign(:deltas, deltas)
        |> assign(:channel_chart_json, channel_chart_json)
        |> assign(:hourly_chart_json, hourly_chart_json)
        |> assign(:analytics_last_fetch_at, DateTime.utc_now())

      {{:error, error}, _} ->
        {message, type} = format_error(error)

        socket
        |> assign(:loading, false)
        |> assign(:error, message)
        |> assign(:error_type, type)

      {_, {:error, error}} ->
        {message, type} = format_error(error)

        socket
        |> assign(:loading, false)
        |> assign(:error, message)
        |> assign(:error_type, type)
    end
  end

  # Date Range Calculations

  defp calculate_date_range("7d") do
    end_date = Date.add(Date.utc_today(), -1)
    start_date = Date.add(end_date, -6)
    {start_date, end_date}
  end

  defp calculate_date_range("30d") do
    end_date = Date.add(Date.utc_today(), -1)
    start_date = Date.add(end_date, -29)
    {start_date, end_date}
  end

  defp calculate_date_range("90d") do
    end_date = Date.add(Date.utc_today(), -1)
    start_date = Date.add(end_date, -89)
    {start_date, end_date}
  end

  defp calculate_date_range(_), do: calculate_date_range("30d")

  defp previous_period(start_date, end_date) do
    days = Date.diff(end_date, start_date)
    prev_end = Date.add(start_date, -1)
    prev_start = Date.add(prev_end, -days)
    {prev_start, prev_end}
  end

  # Data Transformation

  defp transform_metrics(%{"data" => %{"performance" => %{"intervals" => intervals}}})
       when is_list(intervals) and length(intervals) > 0 do
    interval = List.first(intervals)
    sales = get_in(interval, ["sales"]) || %{}
    traffic = get_in(interval, ["traffic"]) || %{}

    %{
      gmv: parse_amount(get_in(sales, ["gmv", "overall", "amount"])),
      gross_revenue: parse_amount(get_in(sales, ["gross_revenue", "overall", "amount"])),
      refunds: parse_amount(get_in(sales, ["refunds", "amount"])),
      orders: get_in(sales, ["orders_count"]) || 0,
      items_sold: get_in(sales, ["items_sold"]) || 0,
      conversion_rate: parse_percentage(get_in(traffic, ["avg_conversation_rate"])),
      gmv_by_channel: parse_channel_breakdowns(sales)
    }
  end

  defp transform_metrics(_), do: nil

  defp parse_channel_breakdowns(sales) do
    breakdowns = get_in(sales, ["gmv", "breakdowns"]) || []

    Enum.reduce(breakdowns, %{live: 0.0, video: 0.0, product_card: 0.0}, fn breakdown, acc ->
      parse_channel_breakdown(breakdown, acc)
    end)
  end

  defp parse_channel_breakdown(breakdown, acc) do
    type = breakdown["type"]
    amount = parse_amount(get_in(breakdown, ["gmv", "amount"]))

    case type do
      "LIVE" -> Map.put(acc, :live, amount)
      "VIDEO" -> Map.put(acc, :video, amount)
      "PRODUCT_CARD" -> Map.put(acc, :product_card, amount)
      _ -> acc
    end
  end

  defp parse_amount(nil), do: 0.0
  defp parse_amount(amount) when is_binary(amount), do: String.to_float(amount)
  defp parse_amount(amount) when is_number(amount), do: amount / 1

  defp parse_percentage(nil), do: 0.0

  defp parse_percentage(rate) when is_binary(rate) do
    case Float.parse(rate) do
      {float, _} -> Float.round(float * 100, 2)
      :error -> 0.0
    end
  end

  defp parse_percentage(rate) when is_number(rate), do: Float.round(rate * 100, 2)

  # Delta Calculation

  defp calculate_deltas(nil, _), do: nil
  defp calculate_deltas(_, nil), do: nil

  defp calculate_deltas(current, previous) do
    %{
      gmv: calculate_delta(current.gmv, previous.gmv),
      gross_revenue: calculate_delta(current.gross_revenue, previous.gross_revenue),
      refunds: calculate_delta(current.refunds, previous.refunds),
      orders: calculate_delta(current.orders, previous.orders),
      items_sold: calculate_delta(current.items_sold, previous.items_sold),
      conversion_rate: calculate_delta(current.conversion_rate, previous.conversion_rate)
    }
  end

  defp calculate_delta(_current, previous) when previous == 0 or previous == 0.0, do: nil

  defp calculate_delta(current, previous) do
    Float.round((current - previous) / previous * 100, 1)
  end

  # Chart JSON Builders

  defp build_channel_chart_json(nil), do: Jason.encode!(%{labels: [], data: [], colors: []})

  defp build_channel_chart_json(%{gmv_by_channel: channels}) do
    Jason.encode!(%{
      labels: ["LIVE", "Video", "Product Card"],
      data: [channels.live, channels.video, channels.product_card],
      colors: [
        "rgb(239, 68, 68)",
        "rgb(59, 130, 246)",
        "rgb(34, 197, 94)"
      ]
    })
  end

  defp build_hourly_chart_json(%{"data" => %{"performance_per_hour" => hourly_data}})
       when is_list(hourly_data) do
    sorted =
      Enum.sort_by(hourly_data, fn h -> h["hour"] end)

    labels = Enum.map(sorted, fn h -> format_hour(h["hour"]) end)
    gmv_values = Enum.map(sorted, fn h -> parse_amount(get_in(h, ["gmv", "amount"])) end)

    visitors =
      Enum.map(sorted, fn h -> get_in(h, ["traffic", "visitors"]) || 0 end)

    Jason.encode!(%{
      labels: labels,
      hasGmv: true,
      datasets: [
        %{
          label: "GMV",
          data: gmv_values,
          borderColor: "rgb(34, 197, 94)",
          backgroundColor: "rgba(34, 197, 94, 0.1)",
          fill: true,
          tension: 0.4,
          yAxisID: "y1"
        },
        %{
          label: "Visitors",
          data: visitors,
          borderColor: "rgb(59, 130, 246)",
          backgroundColor: "transparent",
          borderDash: [5, 5],
          tension: 0.4,
          yAxisID: "y"
        }
      ]
    })
  end

  defp build_hourly_chart_json(_), do: Jason.encode!(%{labels: [], datasets: []})

  defp format_hour(hour) when is_integer(hour) do
    cond do
      hour == 0 -> "12am"
      hour < 12 -> "#{hour}am"
      hour == 12 -> "12pm"
      true -> "#{hour - 12}pm"
    end
  end

  defp format_hour(_), do: ""

  # Formatting Helpers

  def format_currency(nil), do: "$0"

  def format_currency(amount) when is_number(amount) do
    cond do
      amount >= 1_000_000 ->
        "$#{Float.round(amount / 1_000_000, 2)}M"

      amount >= 1_000 ->
        "$#{Float.round(amount / 1_000, 1)}K"

      true ->
        "$#{:erlang.float_to_binary(amount / 1, decimals: 2)}"
    end
  end

  def format_number(nil), do: "0"

  def format_number(num) when is_integer(num) do
    num
    |> Integer.to_string()
    |> add_commas()
  end

  def format_number(num) when is_float(num), do: format_number(trunc(num))

  defp add_commas(str) do
    str
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  def format_percentage(nil), do: "0%"
  def format_percentage(rate), do: "#{Float.round(rate / 1, 2)}%"

  # Returns {message, error_type}
  defp format_error(error) when is_binary(error) do
    cond do
      # Check for scope/authorization errors (code 105005)
      String.contains?(error, "105005") ->
        {"The TikTok Shop app needs the Analytics permission scope. Please re-authorize with the data.shop_analytics.public.read scope enabled.",
         :scope_required}

      # Check for 401 unauthorized
      String.contains?(error, "HTTP 401") ->
        {"TikTok Shop authorization required", :unauthorized}

      # Check for rate limiting
      String.contains?(error, "HTTP 429") ->
        {"Rate limited by TikTok Shop API. Please try again later.", :rate_limited}

      # Generic HTTP error
      String.starts_with?(error, "HTTP ") ->
        {error, :api_error}

      true ->
        {error, :general}
    end
  end

  defp format_error(:unauthorized),
    do: {"TikTok Shop authorization required", :unauthorized}

  defp format_error(:no_auth_record),
    do:
      {"TikTok Shop is not connected. Please connect your TikTok Shop account first.",
       :not_connected}

  defp format_error(:not_found),
    do: {"Analytics data not found", :not_found}

  defp format_error({:rate_limited, _}),
    do: {"Rate limited by TikTok Shop API. Please try again later.", :rate_limited}

  defp format_error(_),
    do: {"Failed to load analytics data", :general}

  def has_channel_data?(nil), do: false

  def has_channel_data?(%{gmv_by_channel: channels}) do
    channels.live > 0 or channels.video > 0 or channels.product_card > 0
  end

  def has_channel_data?(_), do: false

  # Path helpers

  defp analytics_path(socket, params) do
    query =
      params
      |> Enum.reject(fn {_k, v} -> v == "" or is_nil(v) or v == "30d" end)
      |> Map.new()

    suffix = if query == %{}, do: "", else: "?" <> URI.encode_query(query)

    BrandRoutes.brand_path(
      socket.assigns.current_brand,
      "/shop-analytics#{suffix}",
      socket.assigns.current_host
    )
  end
end
