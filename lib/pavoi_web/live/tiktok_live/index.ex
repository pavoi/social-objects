defmodule PavoiWeb.TiktokLive.Index do
  @moduledoc """
  LiveView for browsing TikTok Live stream data.

  Displays a list of captured streams with filtering and search.
  Modal overlay for stream details with tabbed interface (comments, stats, raw data).
  Real-time updates when viewing a currently capturing stream.
  """
  use PavoiWeb, :live_view

  import Ecto.Query

  on_mount {PavoiWeb.NavHooks, :set_current_page}

  alias Pavoi.Repo
  alias Pavoi.Sessions
  alias Pavoi.Settings
  alias Pavoi.TiktokLive, as: TiktokLiveContext
  alias Pavoi.Workers.StreamReportWorker

  import PavoiWeb.TiktokLiveComponents
  import PavoiWeb.ViewHelpers

  @per_page 20
  @comments_per_page 50
  @stream_report_poll_ms 2_000

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to global TikTok live events
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Pavoi.PubSub, "tiktok_live:events")
      Phoenix.PubSub.subscribe(Pavoi.PubSub, "tiktok_live:scan")
    end

    last_scan_at = Settings.get_tiktok_live_last_scan_at()

    socket =
      socket
      |> assign(:live_streams, [])
      |> assign(:total, 0)
      |> assign(:page, 1)
      |> assign(:per_page, @per_page)
      |> assign(:has_more, false)
      |> assign(:loading_streams, false)
      |> assign(:search_query, "")
      |> assign(:status_filter, "all")
      |> assign(:date_filter, "all")
      |> assign(:sort_by, "started")
      |> assign(:sort_dir, "desc")
      # Modal state
      |> assign(:selected_stream, nil)
      |> assign(:stream_summary, nil)
      |> assign(:active_tab, "comments")
      |> stream(:comments, [])
      |> assign(:has_comments, false)
      |> assign(:comment_search_query, "")
      |> assign(:stream_stats, [])
      |> assign(:stream_gmv, nil)
      # Track which stream we're subscribed to for real-time updates
      |> assign(:subscribed_stream_id, nil)
      # Capture form state (dev only)
      |> assign(:dev_mode, Application.get_env(:pavoi, :dev_routes, false))
      |> assign(:capture_input, "")
      |> assign(:capture_loading, false)
      |> assign(:capture_error, nil)
      |> assign(:scanning, false)
      |> assign(:last_scan_at, last_scan_at)
      |> assign(:sending_stream_report, false)
      |> assign(:slack_dev_user_id_present, slack_dev_user_id_present?())
      |> assign(:stream_report_last_sent_at, nil)
      |> assign(:stream_report_last_error, nil)
      # Session linking state
      |> assign(:linked_sessions, [])
      |> assign(:all_sessions, [])
      |> assign(:session_search_query, "")
      |> assign(:product_interest, [])
      # Analytics tab state
      |> assign(:page_tab, "streams")
      |> assign(:analytics_stream_id, nil)
      |> assign(:analytics_sentiment, nil)
      |> assign(:analytics_category, nil)
      |> assign(:analytics_search, "")
      |> assign(:analytics_page, 1)
      |> assign(:sentiment_breakdown, nil)
      |> assign(:category_breakdown, [])
      # Pre-computed chart data JSON to prevent unnecessary re-renders
      |> assign(:sentiment_chart_json, nil)
      |> assign(:category_chart_json, nil)
      |> assign(:analytics_comments, [])
      |> assign(:analytics_comments_total, 0)
      |> assign(:analytics_has_more, false)
      |> assign(:analytics_loading, false)
      |> assign(:streams_sentiment, %{})
      |> assign(:all_streams_for_select, [])
      |> assign(:prev_analytics_stream_id, :not_set)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> apply_params(params)
      |> load_streams()
      |> load_streams_sentiment()
      |> maybe_load_analytics_data()
      |> maybe_load_selected_stream(params)

    {:noreply, socket}
  end

  # Event handlers

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    params = build_query_params(socket, status_filter: status, page: 1)
    {:noreply, push_patch(socket, to: ~p"/streams?#{params}")}
  end

  @impl true
  def handle_event("filter_date", %{"date" => date}, socket) do
    params = build_query_params(socket, date_filter: date, page: 1)
    {:noreply, push_patch(socket, to: ~p"/streams?#{params}")}
  end

  @impl true
  def handle_event("search_streams", %{"value" => query}, socket) do
    params = build_query_params(socket, search_query: query, page: 1)
    {:noreply, push_patch(socket, to: ~p"/streams?#{params}")}
  end

  @impl true
  def handle_event("sort_column", %{"field" => field, "dir" => dir}, socket) do
    params = build_query_params(socket, sort_by: field, sort_dir: dir, page: 1)
    {:noreply, push_patch(socket, to: ~p"/streams?#{params}")}
  end

  @impl true
  def handle_event("scan_streams", _params, socket) do
    socket =
      case TiktokLiveContext.check_live_status_now("manual") do
        {:ok, _job} ->
          assign(socket, :scanning, true)

        {:error, changeset} ->
          socket
          |> assign(:scanning, false)
          |> put_flash(:error, "Failed to scan streams: #{inspect(changeset.errors)}")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("navigate_to_stream", %{"id" => id}, socket) do
    params = build_query_params(socket, stream_id: id)
    {:noreply, push_patch(socket, to: ~p"/streams?#{params}")}
  end

  @impl true
  def handle_event("close_stream_modal", _params, socket) do
    # Unsubscribe from stream-specific updates
    socket = maybe_unsubscribe_from_stream(socket)

    params = build_query_params(socket, stream_id: nil, tab: nil)

    socket =
      socket
      |> assign(:selected_stream, nil)
      |> assign(:stream_summary, nil)
      |> assign(:active_tab, "comments")
      |> stream(:comments, [], reset: true)
      |> assign(:has_comments, false)
      |> assign(:comment_search_query, "")
      |> assign(:stream_stats, [])
      |> assign(:stream_gmv, nil)
      |> assign(:linked_sessions, [])
      |> assign(:all_sessions, [])
      |> assign(:session_search_query, "")
      |> assign(:product_interest, [])
      |> push_patch(to: ~p"/streams?#{params}")

    {:noreply, socket}
  end

  @impl true
  def handle_event("change_tab", %{"tab" => tab}, socket) do
    params = build_query_params(socket, tab: tab)
    {:noreply, push_patch(socket, to: ~p"/streams?#{params}")}
  end

  @impl true
  def handle_event("delete_stream", %{"id" => id}, socket) do
    stream_id = String.to_integer(id)

    case TiktokLiveContext.delete_stream(stream_id) do
      {:ok, _stream} ->
        socket =
          socket
          |> maybe_unsubscribe_from_stream()
          |> assign(:selected_stream, nil)
          |> assign(:stream_summary, nil)
          |> assign(:active_tab, "comments")
          |> stream(:comments, [], reset: true)
          |> assign(:has_comments, false)
          |> assign(:comment_search_query, "")
          |> assign(:stream_stats, [])
          |> assign(:page, 1)
          |> load_streams()
          |> push_patch(to: ~p"/streams")

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("send_stream_report", %{"id" => id}, socket) do
    socket =
      if socket.assigns.dev_mode do
        maybe_send_stream_report(socket, id)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("search_comments", %{"value" => query}, socket) do
    socket =
      socket
      |> assign(:comment_search_query, query)
      |> load_comments()

    {:noreply, socket}
  end

  @impl true
  def handle_event("link_session", %{"session-id" => session_id} = params, socket) do
    stream_id = socket.assigns.selected_stream.id
    session_id = String.to_integer(session_id)

    # If linking from a suggestion, mark as "auto" linked
    linked_by = if params["source"] == "suggestion", do: "auto", else: "manual"

    case TiktokLiveContext.link_stream_to_session(stream_id, session_id, linked_by: linked_by) do
      {:ok, _} ->
        linked = TiktokLiveContext.get_linked_sessions(stream_id)
        product_interest = load_product_interest(stream_id, linked)

        socket =
          socket
          |> assign(:linked_sessions, linked)
          |> assign(:product_interest, product_interest)
          |> load_available_sessions()
          |> put_flash(:info, "Session linked and comments parsed")

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to link session")}
    end
  end

  @impl true
  def handle_event("unlink_session", %{"session-id" => session_id}, socket) do
    stream_id = socket.assigns.selected_stream.id
    session_id = String.to_integer(session_id)

    TiktokLiveContext.unlink_stream_from_session(stream_id, session_id)

    linked = TiktokLiveContext.get_linked_sessions(stream_id)
    product_interest = load_product_interest(stream_id, linked)

    socket =
      socket
      |> assign(:linked_sessions, linked)
      |> assign(:product_interest, product_interest)
      |> load_available_sessions()
      |> put_flash(:info, "Session unlinked")

    {:noreply, socket}
  end

  @impl true
  def handle_event("search_sessions", %{"value" => query}, socket) do
    socket =
      socket
      |> assign(:session_search_query, query)
      |> load_available_sessions()

    {:noreply, socket}
  end

  # Analytics tab event handlers

  @impl true
  def handle_event("change_page_tab", %{"tab" => tab}, socket) do
    params = build_query_params(socket, page_tab: tab, analytics_page: 1)
    {:noreply, push_patch(socket, to: ~p"/streams?#{params}")}
  end

  @impl true
  def handle_event("analytics_select_stream", %{"stream_id" => stream_id}, socket) do
    stream_id = parse_optional_int(stream_id)
    params = build_query_params(socket, analytics_stream_id: stream_id, analytics_page: 1)
    {:noreply, push_patch(socket, to: ~p"/streams?#{params}")}
  end

  @impl true
  def handle_event("analytics_filter_sentiment", %{"sentiment" => sentiment}, socket) do
    sentiment = parse_sentiment(sentiment)
    params = build_query_params(socket, analytics_sentiment: sentiment, analytics_page: 1)
    {:noreply, push_patch(socket, to: ~p"/streams?#{params}")}
  end

  @impl true
  def handle_event("analytics_filter_category", %{"category" => category}, socket) do
    category = parse_category(category)
    params = build_query_params(socket, analytics_category: category, analytics_page: 1)
    {:noreply, push_patch(socket, to: ~p"/streams?#{params}")}
  end

  @impl true
  def handle_event("analytics_search", %{"value" => query}, socket) do
    params = build_query_params(socket, analytics_search: query, analytics_page: 1)
    {:noreply, push_patch(socket, to: ~p"/streams?#{params}")}
  end

  @impl true
  def handle_event("analytics_load_more", _params, socket) do
    send(self(), :load_more_analytics)
    {:noreply, assign(socket, :analytics_loading, true)}
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    send(self(), :load_more_streams)
    {:noreply, assign(socket, :loading_streams, true)}
  end

  @impl true
  def handle_event("start_capture", %{"unique_id" => unique_id}, socket) do
    unique_id = unique_id |> String.trim() |> String.trim_leading("@")

    if unique_id == "" do
      {:noreply, assign(socket, :capture_error, "Enter a username")}
    else
      # Start capture async to avoid blocking
      socket =
        socket
        |> assign(:capture_input, unique_id)
        |> assign(:capture_loading, true)
        |> assign(:capture_error, nil)

      pid = self()

      Task.start(fn ->
        result = TiktokLiveContext.start_capture(unique_id)
        send(pid, {:capture_result, result})
      end)

      {:noreply, socket}
    end
  end

  # PubSub handlers for global "tiktok_live:events" topic
  # Format: {:tiktok_live_event, stream_id, event}

  @impl true
  def handle_info({:tiktok_live_event, _stream_id, %{type: :stream_started}}, socket) do
    # A new stream started - reload the list if we're showing capturing streams
    if socket.assigns.status_filter in ["all", "capturing"] do
      socket =
        socket
        |> assign(:page, 1)
        |> load_streams()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:tiktok_live_event, stream_id, %{type: :stream_ended}}, socket) do
    # A stream ended - update the list
    socket =
      socket
      |> assign(:page, 1)
      |> load_streams()

    # If we're viewing this stream, reload its details
    if socket.assigns.selected_stream && socket.assigns.selected_stream.id == stream_id do
      stream = TiktokLiveContext.get_stream!(stream_id)
      summary = TiktokLiveContext.get_stream_summary(stream_id)

      socket =
        socket
        |> assign(:selected_stream, stream)
        |> assign(:stream_summary, summary)
        |> maybe_unsubscribe_from_stream()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:tiktok_live_event, stream_id, %{type: :connected}}, socket) do
    # A stream connected/reconnected - update the list to show current status
    socket =
      socket
      |> assign(:page, 1)
      |> load_streams()

    # If we're viewing this stream, reload its details
    if socket.assigns.selected_stream && socket.assigns.selected_stream.id == stream_id do
      stream = TiktokLiveContext.get_stream!(stream_id)
      summary = TiktokLiveContext.get_stream_summary(stream_id)

      socket =
        socket
        |> assign(:selected_stream, stream)
        |> assign(:stream_summary, summary)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:tiktok_live_event, stream_id, %{type: :viewer_count} = event}, socket) do
    # Update the viewer count for this stream in the list
    updated_streams =
      Enum.map(socket.assigns.live_streams, fn stream ->
        if stream.id == stream_id do
          viewer_count = event.viewer_count || 0
          %{stream | viewer_count_current: viewer_count}
        else
          stream
        end
      end)

    {:noreply, assign(socket, :live_streams, updated_streams)}
  end

  @impl true
  def handle_info({:tiktok_live_event, stream_id, %{type: :comment}}, socket) do
    # Update the comment count for this stream in the list
    updated_streams =
      Enum.map(socket.assigns.live_streams, fn stream ->
        if stream.id == stream_id do
          %{stream | total_comments: (stream.total_comments || 0) + 1}
        else
          stream
        end
      end)

    {:noreply, assign(socket, :live_streams, updated_streams)}
  end

  # Catch-all for other global events we don't need to handle
  @impl true
  def handle_info({:tiktok_live_event, _stream_id, _event}, socket) do
    {:noreply, socket}
  end

  # PubSub handlers for stream-specific "tiktok_live:stream:#{id}" topic
  # Format: {:tiktok_live_stream_event, {event_type, event_data}}

  @impl true
  def handle_info({:tiktok_live_stream_event, {:comment, comment}}, socket) do
    # New comment for the stream we're viewing - add directly for real-time display
    if socket.assigns.selected_stream &&
         socket.assigns.active_tab == "comments" &&
         socket.assigns.comment_search_query == "" do
      # Build a comment with a unique ID for the stream
      new_comment = %{
        id: "rt-#{System.unique_integer([:positive, :monotonic])}",
        tiktok_username: comment.username,
        tiktok_nickname: comment.nickname,
        comment_text: comment.content,
        commented_at: comment.timestamp || DateTime.utc_now()
      }

      # Insert at the top of the stream (newest first)
      socket =
        socket
        |> stream_insert(:comments, new_comment, at: 0)
        |> assign(:has_comments, true)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:tiktok_live_stream_event, {:viewer_count, _count}}, socket) do
    # Viewer count update - reload stream stats
    if socket.assigns.selected_stream do
      stream = TiktokLiveContext.get_stream!(socket.assigns.selected_stream.id)

      socket =
        socket
        |> assign(:selected_stream, stream)

      # Reload stats if on stats tab
      socket =
        if socket.assigns.active_tab == "stats" do
          stats = TiktokLiveContext.list_stream_stats(stream.id)
          assign(socket, :stream_stats, stats)
        else
          socket
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:tiktok_live_stream_event, {:connected}}, socket) do
    # Stream reconnected - refresh its data to show updated status
    if socket.assigns.selected_stream do
      stream = TiktokLiveContext.get_stream!(socket.assigns.selected_stream.id)
      summary = TiktokLiveContext.get_stream_summary(stream.id)

      socket =
        socket
        |> assign(:selected_stream, stream)
        |> assign(:stream_summary, summary)
        |> load_streams()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:tiktok_live_stream_event, {:stream_ended}}, socket) do
    # Stream we're viewing ended
    if socket.assigns.selected_stream do
      stream = TiktokLiveContext.get_stream!(socket.assigns.selected_stream.id)
      summary = TiktokLiveContext.get_stream_summary(stream.id)

      socket =
        socket
        |> assign(:selected_stream, stream)
        |> assign(:stream_summary, summary)
        |> maybe_unsubscribe_from_stream()
        |> load_streams()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Catch-all for other stream events (likes, gifts, joins, etc.)
  @impl true
  def handle_info({:tiktok_live_stream_event, _event}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(:load_more_streams, socket) do
    socket =
      socket
      |> assign(:page, socket.assigns.page + 1)
      |> load_streams(append: true)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:load_more_analytics, socket) do
    socket =
      socket
      |> assign(:analytics_page, socket.assigns.analytics_page + 1)
      |> load_analytics_comments(append: true)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:capture_result, {:ok, _stream}}, socket) do
    socket =
      socket
      |> assign(:capture_input, "")
      |> assign(:capture_loading, false)
      |> assign(:capture_error, nil)
      |> assign(:page, 1)
      |> load_streams()

    {:noreply, socket}
  end

  @impl true
  def handle_info({:capture_result, {:error, :not_live}}, socket) do
    socket =
      socket
      |> assign(:capture_loading, false)
      |> assign(:capture_error, "User is not live")

    {:noreply, socket}
  end

  @impl true
  def handle_info({:capture_result, {:error, reason}}, socket) do
    error_msg =
      case reason do
        :room_id_not_found -> "User not found or not live"
        {:http_error, status} -> "TikTok returned #{status}"
        _ -> "Failed to connect"
      end

    socket =
      socket
      |> assign(:capture_loading, false)
      |> assign(:capture_error, error_msg)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:scan_completed, _source}, socket) do
    last_scan_at = Settings.get_tiktok_live_last_scan_at()

    socket =
      socket
      |> assign(:last_scan_at, last_scan_at)
      |> assign(:scanning, false)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:refresh_stream_report_status, stream_id}, socket) do
    socket =
      if socket.assigns.dev_mode &&
           socket.assigns.selected_stream &&
           socket.assigns.selected_stream.id == stream_id do
        status = stream_report_job_status(stream_id)

        socket =
          socket
          |> assign_stream_report_status(status)
          |> maybe_schedule_stream_report_poll(stream_id, status)

        socket
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Private functions

  defp apply_params(socket, params) do
    socket
    |> assign(:search_query, params["q"] || "")
    |> assign(:status_filter, params["status"] || "all")
    |> assign(:date_filter, params["date"] || "all")
    |> assign(:sort_by, params["sort"] || "started")
    |> assign(:sort_dir, params["dir"] || "desc")
    |> assign(:page, parse_page(params["page"]))
    # Analytics params
    |> assign(:page_tab, params["pt"] || "streams")
    |> assign(:analytics_stream_id, parse_optional_int(params["as"]))
    |> assign(:analytics_sentiment, parse_sentiment(params["asent"]))
    |> assign(:analytics_category, parse_category(params["acat"]))
    |> assign(:analytics_search, params["asq"] || "")
    |> assign(:analytics_page, parse_page(params["ap"]))
  end

  defp parse_page(nil), do: 1
  defp parse_page(page) when is_binary(page), do: String.to_integer(page)
  defp parse_page(page) when is_integer(page), do: page

  defp load_streams(socket, opts \\ [append: false]) do
    append = Keyword.get(opts, :append, false)
    page = if append, do: socket.assigns.page, else: 1

    filters = build_filters(socket.assigns)

    streams =
      TiktokLiveContext.list_streams(
        filters ++
          [
            limit: @per_page,
            offset: (page - 1) * @per_page
          ]
      )

    total = count_streams(filters)
    has_more = length(streams) == @per_page && page * @per_page < total

    all_streams =
      if append do
        socket.assigns.live_streams ++ streams
      else
        streams
      end

    socket
    |> assign(:loading_streams, false)
    |> assign(:live_streams, all_streams)
    |> assign(:total, total)
    |> assign(:page, page)
    |> assign(:has_more, has_more)
  end

  defp build_filters(assigns) do
    []
    |> apply_search_filter(assigns.search_query)
    |> apply_status_filter(assigns.status_filter)
    |> apply_date_filter(assigns.date_filter)
    |> apply_sort_filter(assigns.sort_by, assigns.sort_dir)
  end

  defp apply_sort_filter(filters, sort_by, sort_dir) do
    filters
    |> Keyword.put(:sort_by, sort_by)
    |> Keyword.put(:sort_dir, sort_dir)
  end

  defp apply_search_filter(filters, ""), do: filters
  defp apply_search_filter(filters, query), do: [{:search, query} | filters]

  defp apply_status_filter(filters, "capturing"), do: [{:status, :capturing} | filters]
  defp apply_status_filter(filters, "ended"), do: [{:status, :ended} | filters]
  defp apply_status_filter(filters, "failed"), do: [{:status, :failed} | filters]
  defp apply_status_filter(filters, _), do: filters

  defp apply_date_filter(filters, "today") do
    today_start = Date.utc_today() |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    [{:started_after, today_start} | filters]
  end

  defp apply_date_filter(filters, "week") do
    week_ago = Date.utc_today() |> Date.add(-7) |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    [{:started_after, week_ago} | filters]
  end

  defp apply_date_filter(filters, "month") do
    month_ago = Date.utc_today() |> Date.add(-30) |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    [{:started_after, month_ago} | filters]
  end

  defp apply_date_filter(filters, _), do: filters

  defp count_streams(filters) do
    TiktokLiveContext.count_streams(filters)
  end

  defp maybe_load_selected_stream(socket, params) do
    case params["s"] do
      nil ->
        socket
        |> assign(:selected_stream, nil)
        |> assign(:stream_summary, nil)
        |> assign(:active_tab, "comments")
        |> assign(:sending_stream_report, false)
        |> assign(:stream_report_last_sent_at, nil)
        |> assign(:stream_report_last_error, nil)
        |> maybe_unsubscribe_from_stream()

      stream_id ->
        try do
          stream_id = String.to_integer(stream_id)
          stream = TiktokLiveContext.get_stream!(stream_id)
          summary = TiktokLiveContext.get_stream_summary(stream_id)
          tab = params["tab"] || "comments"

          socket =
            socket
            |> assign(:selected_stream, stream)
            |> assign(:stream_summary, summary)
            |> assign(:active_tab, tab)
            |> load_tab_data(tab, stream_id)
            |> maybe_subscribe_to_stream(stream)
            |> maybe_assign_stream_report_status(stream_id)

          socket
        rescue
          Ecto.NoResultsError ->
            push_patch(socket, to: ~p"/streams")

          ArgumentError ->
            push_patch(socket, to: ~p"/streams")
        end
    end
  end

  defp load_tab_data(socket, "comments", stream_id) do
    load_comments(socket, stream_id: stream_id)
  end

  defp load_tab_data(socket, "stats", stream_id) do
    stats = TiktokLiveContext.list_stream_stats(stream_id)
    stream = socket.assigns.selected_stream

    # Build GMV data from stored hourly data (if available)
    gmv_data = build_gmv_from_stored(stream)

    socket
    |> assign(:stream_stats, stats)
    |> assign(:stream_gmv, gmv_data)
  end

  defp load_tab_data(socket, "sessions", stream_id) do
    linked = TiktokLiveContext.get_linked_sessions(stream_id)
    product_interest = load_product_interest(stream_id, linked)

    socket
    |> assign(:linked_sessions, linked)
    |> assign(:product_interest, product_interest)
    |> load_available_sessions()
  end

  defp load_tab_data(socket, _tab, _stream_id), do: socket

  defp load_comments(socket, opts \\ []) do
    stream_id = Keyword.get(opts, :stream_id, socket.assigns.selected_stream.id)

    comments =
      if socket.assigns.comment_search_query != "" do
        # Search mode - use search function
        TiktokLiveContext.search_comments(
          stream_id,
          socket.assigns.comment_search_query,
          limit: @comments_per_page
        )
      else
        # Load most recent comments
        result =
          TiktokLiveContext.list_stream_comments(
            stream_id,
            page: 1,
            per_page: @comments_per_page,
            order: :desc
          )

        result.comments
      end

    socket
    |> stream(:comments, comments, reset: true)
    |> assign(:has_comments, length(comments) > 0)
  end

  defp maybe_subscribe_to_stream(socket, %{status: :capturing, id: stream_id}) do
    # Only subscribe if not already subscribed to this stream
    if socket.assigns.subscribed_stream_id != stream_id do
      # Unsubscribe from previous stream if any
      socket = maybe_unsubscribe_from_stream(socket)

      # Subscribe to new stream
      Phoenix.PubSub.subscribe(Pavoi.PubSub, "tiktok_live:stream:#{stream_id}")
      assign(socket, :subscribed_stream_id, stream_id)
    else
      socket
    end
  end

  defp maybe_subscribe_to_stream(socket, _stream), do: socket

  defp maybe_unsubscribe_from_stream(socket) do
    if socket.assigns.subscribed_stream_id do
      Phoenix.PubSub.unsubscribe(
        Pavoi.PubSub,
        "tiktok_live:stream:#{socket.assigns.subscribed_stream_id}"
      )

      assign(socket, :subscribed_stream_id, nil)
    else
      socket
    end
  end

  @key_mapping %{
    search_query: :q,
    status_filter: :status,
    date_filter: :date,
    sort_by: :sort,
    sort_dir: :dir,
    page: :page,
    stream_id: :s,
    tab: :tab,
    # Analytics keys
    page_tab: :pt,
    analytics_stream_id: :as,
    analytics_sentiment: :asent,
    analytics_category: :acat,
    analytics_search: :asq,
    analytics_page: :ap
  }

  defp build_query_params(socket, overrides) do
    base = %{
      q: socket.assigns.search_query,
      status: socket.assigns.status_filter,
      date: socket.assigns.date_filter,
      sort: socket.assigns.sort_by,
      dir: socket.assigns.sort_dir,
      page: socket.assigns.page,
      s: get_stream_id(socket.assigns.selected_stream),
      tab: socket.assigns.active_tab,
      # Analytics params
      pt: socket.assigns.page_tab,
      as: socket.assigns.analytics_stream_id,
      asent: format_atom_param(socket.assigns.analytics_sentiment),
      acat: format_atom_param(socket.assigns.analytics_category),
      asq: socket.assigns.analytics_search,
      ap: socket.assigns.analytics_page
    }

    overrides
    |> Enum.reduce(base, fn {key, value}, acc ->
      Map.put(acc, Map.fetch!(@key_mapping, key), format_param_value(value))
    end)
    |> reject_default_values()
  end

  defp format_param_value(value) when is_atom(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp format_param_value(value), do: value

  defp get_stream_id(nil), do: nil
  defp get_stream_id(stream), do: stream.id

  defp reject_default_values(params) do
    params
    |> Enum.reject(&default_value?/1)
    |> Map.new()
  end

  defp default_value?({_k, ""}), do: true
  defp default_value?({_k, nil}), do: true
  defp default_value?({:status, "all"}), do: true
  defp default_value?({:date, "all"}), do: true
  defp default_value?({:sort, "started"}), do: true
  defp default_value?({:dir, "desc"}), do: true
  defp default_value?({:page, 1}), do: true
  defp default_value?({:tab, "comments"}), do: true
  defp default_value?({:pt, "streams"}), do: true
  defp default_value?({:ap, 1}), do: true
  defp default_value?(_), do: false

  defp maybe_send_stream_report(socket, id) do
    cond do
      socket.assigns.sending_stream_report ->
        socket

      not socket.assigns.slack_dev_user_id_present ->
        put_flash(socket, :error, "Slack dev user id not configured")

      true ->
        case Integer.parse(id) do
          {stream_id, ""} ->
            enqueue_stream_report_job(socket, stream_id)

          _ ->
            put_flash(socket, :error, "Invalid stream id")
        end
    end
  end

  defp slack_dev_user_id_present? do
    case Application.get_env(:pavoi, :slack_dev_user_id) do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  defp enqueue_stream_report_job(socket, stream_id) do
    case StreamReportWorker.new(%{stream_id: stream_id}) |> Oban.insert() do
      {:ok, _job} ->
        status = stream_report_job_status(stream_id)

        socket
        |> assign_stream_report_status(status)
        |> maybe_schedule_stream_report_poll(stream_id, status)
        |> put_flash(:info, "Slack report queued")

      {:error, changeset} ->
        socket
        |> assign(:sending_stream_report, false)
        |> assign(:stream_report_last_error, format_stream_report_error(changeset.errors))
        |> put_flash(:error, "Failed to enqueue Slack report: #{inspect(changeset.errors)}")
    end
  end

  defp maybe_assign_stream_report_status(socket, stream_id) do
    if socket.assigns.dev_mode do
      status = stream_report_job_status(stream_id)

      socket
      |> assign_stream_report_status(status)
      |> maybe_schedule_stream_report_poll(stream_id, status)
    else
      socket
    end
  end

  defp assign_stream_report_status(socket, status) do
    socket
    |> assign(:sending_stream_report, status.sending)
    |> assign(:stream_report_last_sent_at, status.last_sent_at)
    |> assign(:stream_report_last_error, status.last_error)
  end

  defp stream_report_job_status(stream_id) do
    worker_name = "Pavoi.Workers.StreamReportWorker"

    job =
      from(j in Oban.Job,
        where: j.worker == ^worker_name,
        where: fragment("?->>'stream_id' = ?", j.args, ^to_string(stream_id)),
        order_by: [desc: j.inserted_at],
        limit: 1
      )
      |> Repo.one()

    case job do
      nil ->
        %{sending: false, last_sent_at: nil, last_error: nil}

      %Oban.Job{} = job ->
        %{
          sending: stream_report_job_active?(job),
          last_sent_at: stream_report_job_sent_at(job),
          last_error: stream_report_job_error(job)
        }
    end
  end

  defp stream_report_job_active?(%Oban.Job{state: "executing"}), do: true
  defp stream_report_job_active?(%Oban.Job{state: "available"}), do: true
  defp stream_report_job_active?(%Oban.Job{state: "retryable"}), do: true

  defp stream_report_job_active?(%Oban.Job{state: "scheduled", scheduled_at: scheduled_at})
       when not is_nil(scheduled_at) do
    DateTime.compare(scheduled_at, DateTime.utc_now()) in [:lt, :eq]
  end

  defp stream_report_job_active?(_job), do: false

  defp stream_report_job_sent_at(%Oban.Job{state: "completed", completed_at: completed_at}),
    do: completed_at

  defp stream_report_job_sent_at(_job), do: nil

  defp stream_report_job_error(%Oban.Job{state: "completed"}), do: nil

  defp stream_report_job_error(%Oban.Job{state: state} = job)
       when state in ["discarded", "cancelled"] do
    message = stream_report_job_error_message(job)
    format_stream_report_job_error(state, message)
  end

  defp stream_report_job_error(%Oban.Job{attempt: attempt} = job) when attempt > 0 do
    message = stream_report_job_error_message(job)

    case job.state do
      "retryable" -> format_stream_report_job_error("retryable", message)
      "scheduled" -> format_stream_report_job_error("retryable", message)
      "available" -> format_stream_report_job_error("retryable", message)
      "executing" -> format_stream_report_job_error("retryable", message)
      _ -> message
    end
  end

  defp stream_report_job_error(_job), do: nil

  defp stream_report_job_error_message(%Oban.Job{errors: errors}) do
    errors
    |> List.last()
    |> case do
      %{"error" => error} -> error
      %{"message" => message} -> message
      %{"exception" => exception} -> exception
      error when is_map(error) -> inspect(error)
      _ -> nil
    end
  end

  defp format_stream_report_job_error("cancelled", nil), do: "Cancelled"
  defp format_stream_report_job_error("discarded", nil), do: "Discarded"
  defp format_stream_report_job_error("retryable", nil), do: "Retrying"
  defp format_stream_report_job_error("retryable", message), do: "Retrying: #{message}"
  defp format_stream_report_job_error(_state, message), do: message

  defp maybe_schedule_stream_report_poll(socket, stream_id, %{sending: true}) do
    Process.send_after(self(), {:refresh_stream_report_status, stream_id}, @stream_report_poll_ms)
    socket
  end

  defp maybe_schedule_stream_report_poll(socket, _stream_id, _status), do: socket

  defp format_stream_report_error(reason) when is_binary(reason), do: reason
  defp format_stream_report_error(reason), do: inspect(reason)

  defp load_available_sessions(socket) do
    linked_ids = Enum.map(socket.assigns.linked_sessions, & &1.id)
    search_query = socket.assigns.session_search_query

    sessions =
      Sessions.list_sessions_with_details_paginated(
        search_query: search_query,
        page: 1,
        per_page: 10
      )

    # Filter out already linked sessions
    available = Enum.reject(sessions.sessions, fn s -> s.id in linked_ids end)

    assign(socket, :all_sessions, available)
  end

  defp load_product_interest(stream_id, linked_sessions) do
    case linked_sessions do
      [session | _] ->
        TiktokLiveContext.get_product_interest_summary(stream_id, session.id)

      [] ->
        []
    end
  end

  defp build_gmv_from_stored(nil), do: nil
  defp build_gmv_from_stored(%{gmv_hourly: nil}), do: nil
  defp build_gmv_from_stored(%{gmv_hourly: %{"data" => []}}), do: nil

  defp build_gmv_from_stored(%{gmv_hourly: %{"data" => data}} = stream) do
    hourly =
      Enum.map(data, fn h ->
        {:ok, hour, _} = DateTime.from_iso8601(h["hour"])

        %{
          hour: hour,
          gmv_cents: h["gmv_cents"],
          order_count: h["order_count"]
        }
      end)

    %{
      hourly: hourly,
      total_gmv_cents: stream.gmv_cents,
      total_orders: stream.gmv_order_count
    }
  end

  defp build_gmv_from_stored(_), do: nil

  # Analytics helper functions

  defp parse_optional_int(nil), do: nil
  defp parse_optional_int(""), do: nil

  defp parse_optional_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_optional_int(value) when is_integer(value), do: value

  defp parse_sentiment(nil), do: nil
  defp parse_sentiment(""), do: nil
  defp parse_sentiment("positive"), do: :positive
  defp parse_sentiment("neutral"), do: :neutral
  defp parse_sentiment("negative"), do: :negative
  defp parse_sentiment(_), do: nil

  defp parse_category(nil), do: nil
  defp parse_category(""), do: nil
  defp parse_category("praise_compliment"), do: :praise_compliment
  defp parse_category("question_confusion"), do: :question_confusion
  defp parse_category("product_request"), do: :product_request
  defp parse_category("concern_complaint"), do: :concern_complaint
  defp parse_category("technical_issue"), do: :technical_issue
  defp parse_category("flash_sale"), do: :flash_sale
  defp parse_category("general"), do: :general
  defp parse_category(_), do: nil

  defp format_atom_param(nil), do: nil
  defp format_atom_param(atom), do: Atom.to_string(atom)

  defp load_streams_sentiment(socket) do
    stream_ids = Enum.map(socket.assigns.live_streams, & &1.id)

    sentiment_map =
      if length(stream_ids) > 0 do
        TiktokLiveContext.get_streams_sentiment_summary(stream_ids)
      else
        %{}
      end

    assign(socket, :streams_sentiment, sentiment_map)
  end

  defp maybe_load_analytics_data(socket) do
    if socket.assigns.page_tab == "analytics" do
      # Check if stream selection changed (charts only need to reload when stream changes)
      prev_stream_id = socket.assigns[:prev_analytics_stream_id]
      curr_stream_id = socket.assigns.analytics_stream_id
      stream_changed = prev_stream_id != curr_stream_id

      # Check if charts need initial load (nil means never loaded)
      charts_need_load = is_nil(socket.assigns.sentiment_breakdown) or stream_changed

      socket
      |> assign(:prev_analytics_stream_id, curr_stream_id)
      |> load_all_streams_for_select()
      |> maybe_load_chart_data(charts_need_load)
      |> load_analytics_comments()
    else
      socket
    end
  end

  defp load_all_streams_for_select(socket) do
    # Only load if not already loaded
    if Enum.empty?(socket.assigns.all_streams_for_select) do
      streams = TiktokLiveContext.list_streams(limit: 100, sort_by: "started", sort_dir: "desc")
      assign(socket, :all_streams_for_select, streams)
    else
      socket
    end
  end

  defp maybe_load_chart_data(socket, false), do: socket

  defp maybe_load_chart_data(socket, true) do
    opts =
      [stream_id: socket.assigns.analytics_stream_id]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    sentiment_breakdown = TiktokLiveContext.get_aggregate_sentiment_breakdown(opts)
    category_breakdown = TiktokLiveContext.get_aggregate_category_breakdown(opts)

    # Pre-compute chart JSON to prevent re-computation on every component render
    sentiment_chart_json = build_sentiment_chart_json(sentiment_breakdown)
    category_chart_json = build_category_chart_json(category_breakdown)

    socket
    |> assign(:sentiment_breakdown, sentiment_breakdown)
    |> assign(:category_breakdown, category_breakdown)
    |> assign(:sentiment_chart_json, sentiment_chart_json)
    |> assign(:category_chart_json, category_chart_json)
  end

  # Build pre-computed chart JSON for stable rendering
  defp build_sentiment_chart_json(nil), do: Jason.encode!(%{labels: [], data: [], colors: []})

  defp build_sentiment_chart_json(breakdown) do
    Jason.encode!(%{
      labels: ["Positive", "Neutral", "Negative"],
      data: [
        breakdown.positive.percent,
        breakdown.neutral.percent,
        breakdown.negative.percent
      ],
      colors: [
        "rgb(34, 197, 94)",
        "rgb(156, 163, 175)",
        "rgb(239, 68, 68)"
      ]
    })
  end

  defp build_category_chart_json([]), do: Jason.encode!(%{labels: [], data: [], colors: []})

  defp build_category_chart_json(categories) do
    category_colors = %{
      praise_compliment: "rgb(34, 197, 94)",
      question_confusion: "rgb(59, 130, 246)",
      product_request: "rgb(168, 85, 247)",
      concern_complaint: "rgb(239, 68, 68)",
      technical_issue: "rgb(249, 115, 22)",
      flash_sale: "rgb(236, 72, 153)",
      general: "rgb(156, 163, 175)"
    }

    category_labels = %{
      praise_compliment: "Praise",
      question_confusion: "Questions",
      product_request: "Product Requests",
      concern_complaint: "Concerns",
      technical_issue: "Technical Issues",
      flash_sale: "Flash Sale",
      general: "General"
    }

    Jason.encode!(%{
      labels: Enum.map(categories, fn c -> Map.get(category_labels, c.category, "Unknown") end),
      data: Enum.map(categories, & &1.count),
      colors:
        Enum.map(categories, fn c ->
          Map.get(category_colors, c.category, "rgb(156, 163, 175)")
        end)
    })
  end

  defp load_analytics_comments(socket, opts \\ []) do
    append = Keyword.get(opts, :append, false)
    page = if append, do: socket.assigns.analytics_page, else: 1
    per_page = 25

    query_opts =
      [
        stream_id: socket.assigns.analytics_stream_id,
        sentiment: socket.assigns.analytics_sentiment,
        category: socket.assigns.analytics_category,
        search: socket.assigns.analytics_search,
        page: page,
        per_page: per_page
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)

    result = TiktokLiveContext.list_classified_comments(query_opts)

    comments =
      if append do
        socket.assigns.analytics_comments ++ result.comments
      else
        result.comments
      end

    socket
    |> assign(:analytics_comments, comments)
    |> assign(:analytics_comments_total, result.total)
    |> assign(:analytics_has_more, result.has_more)
    |> assign(:analytics_page, page)
    |> assign(:analytics_loading, false)
  end
end
