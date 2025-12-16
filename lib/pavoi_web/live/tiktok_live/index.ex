defmodule PavoiWeb.TiktokLive.Index do
  @moduledoc """
  LiveView for browsing TikTok Live stream data.

  Displays a list of captured streams with filtering and search.
  Modal overlay for stream details with tabbed interface (comments, stats, raw data).
  Real-time updates when viewing a currently capturing stream.
  """
  use PavoiWeb, :live_view

  on_mount {PavoiWeb.NavHooks, :set_current_page}

  alias Pavoi.TiktokLive, as: TiktokLiveContext

  import PavoiWeb.TiktokLiveComponents
  import PavoiWeb.ViewHelpers

  @per_page 20
  @comments_per_page 50

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to global TikTok live events
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Pavoi.PubSub, "tiktok_live:events")
    end

    socket =
      socket
      |> assign(:live_streams, [])
      |> assign(:total, 0)
      |> assign(:page, 1)
      |> assign(:per_page, @per_page)
      |> assign(:has_more, false)
      |> assign(:loading_streams, false)
      |> assign(:status_filter, "all")
      |> assign(:date_filter, "all")
      # Modal state
      |> assign(:selected_stream, nil)
      |> assign(:stream_summary, nil)
      |> assign(:active_tab, "comments")
      |> assign(:comments, [])
      |> assign(:comments_page, 1)
      |> assign(:comments_has_more, false)
      |> assign(:comment_search_query, "")
      |> assign(:loading_comments, false)
      |> assign(:stream_stats, [])
      # Track which stream we're subscribed to for real-time updates
      |> assign(:subscribed_stream_id, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> apply_params(params)
      |> load_streams()
      |> maybe_load_selected_stream(params)

    {:noreply, socket}
  end

  # Event handlers

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    params = build_query_params(socket, status_filter: status, page: 1)
    {:noreply, push_patch(socket, to: ~p"/live-streams?#{params}")}
  end

  @impl true
  def handle_event("filter_date", %{"date" => date}, socket) do
    params = build_query_params(socket, date_filter: date, page: 1)
    {:noreply, push_patch(socket, to: ~p"/live-streams?#{params}")}
  end

  @impl true
  def handle_event("navigate_to_stream", %{"id" => id}, socket) do
    params = build_query_params(socket, stream_id: id)
    {:noreply, push_patch(socket, to: ~p"/live-streams?#{params}")}
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
      |> assign(:comments, [])
      |> assign(:comments_page, 1)
      |> assign(:comment_search_query, "")
      |> assign(:stream_stats, [])
      |> push_patch(to: ~p"/live-streams?#{params}")

    {:noreply, socket}
  end

  @impl true
  def handle_event("change_tab", %{"tab" => tab}, socket) do
    params = build_query_params(socket, tab: tab)
    {:noreply, push_patch(socket, to: ~p"/live-streams?#{params}")}
  end

  @impl true
  def handle_event("search_comments", %{"value" => query}, socket) do
    socket =
      socket
      |> assign(:comment_search_query, query)
      |> assign(:comments_page, 1)
      |> load_comments()

    {:noreply, socket}
  end

  @impl true
  def handle_event("load_more_comments", _params, socket) do
    socket =
      socket
      |> assign(:loading_comments, true)
      |> assign(:comments_page, socket.assigns.comments_page + 1)
      |> load_comments(append: true)

    {:noreply, socket}
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    send(self(), :load_more_streams)
    {:noreply, assign(socket, :loading_streams, true)}
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

  # Catch-all for other global events we don't need to handle
  @impl true
  def handle_info({:tiktok_live_event, _stream_id, _event}, socket) do
    {:noreply, socket}
  end

  # PubSub handlers for stream-specific "tiktok_live:stream:#{id}" topic
  # Format: {:tiktok_live_stream_event, {event_type, event_data}}

  @impl true
  def handle_info({:tiktok_live_stream_event, {:comment, _comment}}, socket) do
    # New comment for the stream we're viewing
    if socket.assigns.selected_stream &&
         socket.assigns.active_tab == "comments" &&
         socket.assigns.comment_search_query == "" do
      # Reload comments to get the persisted comment with all fields
      socket = load_comments(socket)
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
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Private functions

  defp apply_params(socket, params) do
    socket
    |> assign(:status_filter, params["status"] || "all")
    |> assign(:date_filter, params["date"] || "all")
    |> assign(:page, parse_page(params["page"]))
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
    filters = []

    filters =
      case assigns.status_filter do
        "all" -> filters
        "capturing" -> [{:status, :capturing} | filters]
        "ended" -> [{:status, :ended} | filters]
        "failed" -> [{:status, :failed} | filters]
        _ -> filters
      end

    filters =
      case assigns.date_filter do
        "all" ->
          filters

        "today" ->
          today_start = Date.utc_today() |> DateTime.new!(~T[00:00:00], "Etc/UTC")
          [{:started_after, today_start} | filters]

        "week" ->
          week_ago = Date.utc_today() |> Date.add(-7) |> DateTime.new!(~T[00:00:00], "Etc/UTC")
          [{:started_after, week_ago} | filters]

        "month" ->
          month_ago = Date.utc_today() |> Date.add(-30) |> DateTime.new!(~T[00:00:00], "Etc/UTC")
          [{:started_after, month_ago} | filters]

        _ ->
          filters
      end

    filters
  end

  defp count_streams(filters) do
    # Get count by listing with filters (could be optimized with a count query)
    length(TiktokLiveContext.list_streams(filters))
  end

  defp maybe_load_selected_stream(socket, params) do
    case params["s"] do
      nil ->
        socket
        |> assign(:selected_stream, nil)
        |> assign(:stream_summary, nil)
        |> assign(:active_tab, "comments")
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

          socket
        rescue
          Ecto.NoResultsError ->
            push_patch(socket, to: ~p"/live-streams")

          ArgumentError ->
            push_patch(socket, to: ~p"/live-streams")
        end
    end
  end

  defp load_tab_data(socket, "comments", stream_id) do
    load_comments(socket, stream_id: stream_id)
  end

  defp load_tab_data(socket, "stats", stream_id) do
    stats = TiktokLiveContext.list_stream_stats(stream_id)
    assign(socket, :stream_stats, stats)
  end

  defp load_tab_data(socket, _tab, _stream_id), do: socket

  defp load_comments(socket, opts \\ []) do
    append = Keyword.get(opts, :append, false)
    stream_id = Keyword.get(opts, :stream_id, socket.assigns.selected_stream.id)

    result =
      if socket.assigns.comment_search_query != "" do
        # Search mode - use search function
        comments =
          TiktokLiveContext.search_comments(
            stream_id,
            socket.assigns.comment_search_query,
            limit: @comments_per_page
          )

        %{comments: comments, has_more: false}
      else
        # Normal pagination mode
        result =
          TiktokLiveContext.list_stream_comments(
            stream_id,
            page: socket.assigns.comments_page,
            per_page: @comments_per_page,
            order: :desc
          )

        %{comments: result.comments, has_more: result.has_more}
      end

    comments =
      if append do
        socket.assigns.comments ++ result.comments
      else
        result.comments
      end

    socket
    |> assign(:loading_comments, false)
    |> assign(:comments, comments)
    |> assign(:comments_has_more, result.has_more)
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
    status_filter: :status,
    date_filter: :date,
    page: :page,
    stream_id: :s,
    tab: :tab
  }

  defp build_query_params(socket, overrides) do
    base = %{
      status: socket.assigns.status_filter,
      date: socket.assigns.date_filter,
      page: socket.assigns.page,
      s: get_stream_id(socket.assigns.selected_stream),
      tab: socket.assigns.active_tab
    }

    overrides
    |> Enum.reduce(base, fn {key, value}, acc ->
      Map.put(acc, Map.fetch!(@key_mapping, key), value)
    end)
    |> reject_default_values()
  end

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
  defp default_value?({:page, 1}), do: true
  defp default_value?({:tab, "comments"}), do: true
  defp default_value?(_), do: false
end
