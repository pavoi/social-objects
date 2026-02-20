defmodule SocialObjectsWeb.VideosLive.Index do
  @moduledoc """
  LiveView for browsing affiliate video performance.

  Displays a paginated, searchable, filterable grid of creator videos.
  """
  use SocialObjectsWeb, :live_view

  on_mount {SocialObjectsWeb.NavHooks, :set_current_page}

  alias SocialObjects.Creators
  alias SocialObjects.Settings
  alias SocialObjectsWeb.BrandRoutes

  import SocialObjectsWeb.ParamHelpers
  import SocialObjectsWeb.VideoComponents

  @default_min_gmv 100_000

  @impl true
  def mount(_params, _session, socket) do
    brand_id = socket.assigns.current_brand.id

    # Subscribe to video sync events
    _ =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(SocialObjects.PubSub, "video:sync:#{brand_id}")
      end

    # Load creators once on mount (doesn't change based on search/filters)
    available_creators =
      if connected?(socket) do
        Creators.list_creators_with_videos(brand_id)
      else
        []
      end

    socket =
      socket
      |> assign(:videos, [])
      |> assign(:search_query, "")
      |> assign(:sort_by, "gmv")
      |> assign(:sort_dir, "desc")
      |> assign(:page, 1)
      |> assign(:per_page, 24)
      |> assign(:total, 0)
      |> assign(:has_more, false)
      |> assign(:loading_videos, false)
      |> assign(:selected_creator_id, nil)
      |> assign(:available_creators, available_creators)
      |> assign(:brand_id, brand_id)
      |> assign(:selected_video, nil)
      # Version counter for search - used to ignore stale async results
      |> assign(:search_version, 0)
      |> assign(:videos_last_import_at, Settings.get_videos_last_import_at(brand_id))
      # Time and min GMV filters
      |> assign(:time_preset, "all")
      |> assign(:min_gmv, nil)
      |> assign(:time_filter_open, false)
      |> assign(:min_gmv_filter_open, false)
      |> assign(:creator_filter_open, false)
      |> assign(:sort_filter_open, false)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> apply_params(params)
      |> start_async_video_load()

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"value" => query}, socket) do
    # Skip if query hasn't actually changed (can happen with rapid events)
    if query == socket.assigns.search_query do
      {:noreply, socket}
    else
      # Handle search locally without push_patch to avoid URL/render churn
      socket =
        socket
        |> assign(:search_query, query)
        |> assign(:page, 1)
        |> start_async_video_load()

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("sort_videos", params, socket) do
    sort_value = params["selection"] || params["value"] || ""
    {sort_by, sort_dir} = parse_sort(sort_value)
    min_gmv = normalize_min_gmv(sort_by, socket.assigns.min_gmv)

    params =
      build_query_params(
        socket,
        sort_by: sort_by,
        sort_dir: sort_dir,
        page: 1,
        min_gmv: min_gmv
      )

    {:noreply,
     socket
     |> assign(:time_filter_open, false)
     |> assign(:min_gmv_filter_open, false)
     |> assign(:sort_filter_open, false)
     |> push_patch(to: videos_path(socket, params))}
  end

  @impl true
  def handle_event("filter_creator", params, socket) do
    creator_id = params["selection"] || params["value"] || ""
    creator_id = parse_id_or_nil(creator_id)
    params = build_query_params(socket, selected_creator_id: creator_id, page: 1)

    {:noreply,
     socket
     |> assign(:creator_filter_open, false)
     |> push_patch(to: videos_path(socket, params))}
  end

  @impl true
  def handle_event("set_time_preset", %{"preset" => preset}, socket) do
    preset = validate_time_preset(preset)
    params = build_query_params(socket, time_preset: preset, page: 1)

    {:noreply,
     socket
     |> assign(:time_filter_open, false)
     |> assign(:min_gmv_filter_open, false)
     |> push_patch(to: videos_path(socket, params))}
  end

  @impl true
  def handle_event("set_min_gmv", %{"amount" => amount}, socket) do
    min_gmv = parse_min_gmv(amount)
    params = build_query_params(socket, min_gmv: min_gmv, page: 1)

    {:noreply,
     socket
     |> assign(:time_filter_open, false)
     |> assign(:min_gmv_filter_open, false)
     |> push_patch(to: videos_path(socket, params))}
  end

  @impl true
  def handle_event("toggle_time_filter", _, socket) do
    time_filter_open = !socket.assigns.time_filter_open

    {:noreply,
     socket
     |> assign(:time_filter_open, time_filter_open)
     |> assign(:min_gmv_filter_open, false)}
  end

  @impl true
  def handle_event("toggle_min_gmv_filter", _, socket) do
    min_gmv_filter_open = !socket.assigns.min_gmv_filter_open

    {:noreply,
     socket
     |> assign(:min_gmv_filter_open, min_gmv_filter_open)
     |> assign(:time_filter_open, false)}
  end

  @impl true
  def handle_event("toggle_creator_filter", _, socket) do
    {:noreply, assign(socket, :creator_filter_open, !socket.assigns.creator_filter_open)}
  end

  @impl true
  def handle_event("toggle_sort_filter", _, socket) do
    {:noreply, assign(socket, :sort_filter_open, !socket.assigns.sort_filter_open)}
  end

  @impl true
  def handle_event("hover_video", %{"id" => id}, socket) do
    video =
      case parse_id(id) do
        {:ok, video_id} -> Enum.find(socket.assigns.videos, &(&1.id == video_id))
        :error -> nil
      end

    {:noreply, assign(socket, :selected_video, video)}
  end

  @impl true
  def handle_event("leave_video", _params, socket) do
    {:noreply, assign(socket, :selected_video, nil)}
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    if socket.assigns.loading_videos or not socket.assigns.has_more do
      {:noreply, socket}
    else
      send(self(), :load_more_videos)
      {:noreply, assign(socket, :loading_videos, true)}
    end
  end

  @impl true
  def handle_info(:load_more_videos, socket) do
    socket =
      socket
      |> assign(:page, socket.assigns.page + 1)
      |> load_more_videos()

    {:noreply, socket}
  end

  # Video sync PubSub handlers - auto-refresh when sync completes from admin dashboard
  @impl true
  def handle_info({:video_sync_started}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:video_sync_completed, stats}, socket) do
    socket =
      socket
      |> assign(
        :videos_last_import_at,
        Settings.get_videos_last_import_at(socket.assigns.brand_id)
      )
      |> assign(:page, 1)
      |> start_async_video_load()
      |> put_flash(
        :info,
        "Synced #{stats.videos_synced} videos (#{stats.creators_created} new creators)"
      )

    {:noreply, socket}
  end

  @impl true
  def handle_info({:video_sync_failed, _reason}, socket) do
    {:noreply, put_flash(socket, :error, "Video sync failed. Please try again.")}
  end

  @impl true
  def handle_async({:load_videos, version}, {:ok, result}, socket) do
    # Only apply results if this is the latest search version
    # Ignore stale results from previous searches
    if version == socket.assigns.search_version do
      socket =
        socket
        |> assign(:loading_videos, false)
        |> assign(:videos, result.videos)
        |> assign(:total, result.total)
        |> assign(:has_more, result.has_more)
        |> assign(:page, 1)

      {:noreply, socket}
    else
      # Stale result, ignore it
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async({:load_videos, _version}, {:exit, _reason}, socket) do
    {:noreply, assign(socket, :loading_videos, false)}
  end

  # Private functions

  defp videos_path(socket, params) when is_map(params) do
    query = URI.encode_query(params)
    path = if query == "", do: "/videos", else: "/videos?#{query}"
    BrandRoutes.brand_path(socket.assigns.current_brand, path, socket.assigns.current_host)
  end

  defp apply_params(socket, params) do
    {sort_by, sort_dir} = parse_sort(params["sort"])
    time_preset = validate_time_preset(params["period"])
    min_gmv = normalize_min_gmv(sort_by, parse_min_gmv(params["min_gmv"]))

    socket
    |> assign(:search_query, params["q"] || "")
    |> assign(:sort_by, sort_by)
    |> assign(:sort_dir, sort_dir)
    |> assign(:page, parse_page(params["page"]))
    |> assign(:selected_creator_id, parse_creator_id(params["creator"]))
    |> assign(:time_preset, time_preset)
    |> assign(:min_gmv, min_gmv)
  end

  # Whitelist-only sort parsing
  defp parse_sort(nil), do: {"gmv", "desc"}
  defp parse_sort(""), do: {"gmv", "desc"}
  defp parse_sort("gmv_desc"), do: {"gmv", "desc"}
  defp parse_sort("gpm_desc"), do: {"gpm", "desc"}
  defp parse_sort("views_desc"), do: {"views", "desc"}
  defp parse_sort("ctr_desc"), do: {"ctr", "desc"}
  defp parse_sort("items_sold_desc"), do: {"items_sold", "desc"}
  defp parse_sort("posted_at_desc"), do: {"posted_at", "desc"}
  defp parse_sort("posted_at_asc"), do: {"posted_at", "asc"}
  defp parse_sort(_), do: {"gmv", "desc"}

  defp parse_page(nil), do: 1
  defp parse_page(""), do: 1
  defp parse_page(page) when is_binary(page), do: parse_id_or_default(page, 1)
  defp parse_page(page) when is_integer(page), do: page

  defp parse_creator_id(nil), do: nil
  defp parse_creator_id(""), do: nil
  defp parse_creator_id(id) when is_binary(id), do: parse_id_or_nil(id)

  defp start_async_video_load(socket) do
    %{
      search_query: search_query,
      sort_by: sort_by,
      sort_dir: sort_dir,
      per_page: per_page,
      selected_creator_id: creator_id,
      brand_id: brand_id,
      search_version: current_version,
      time_preset: time_preset,
      min_gmv: min_gmv
    } = socket.assigns

    # Increment version to track this search request
    new_version = current_version + 1

    opts =
      [
        page: 1,
        per_page: per_page,
        sort_by: sort_by,
        sort_dir: sort_dir,
        brand_id: brand_id,
        period: time_preset
      ]
      |> maybe_add_opt(:search_query, search_query)
      |> maybe_add_opt(:creator_id, creator_id)
      |> maybe_add_opt(:min_gmv, min_gmv)

    socket
    |> assign(:loading_videos, true)
    |> assign(:search_version, new_version)
    |> start_async({:load_videos, new_version}, fn ->
      # Include version in result so we can check if it's stale
      result = Creators.search_videos_paginated(opts)
      Map.put(result, :version, new_version)
    end)
  end

  defp load_more_videos(socket) do
    %{
      search_query: search_query,
      sort_by: sort_by,
      sort_dir: sort_dir,
      page: page,
      per_page: per_page,
      selected_creator_id: creator_id,
      brand_id: brand_id,
      time_preset: time_preset,
      min_gmv: min_gmv
    } = socket.assigns

    opts =
      [
        page: page,
        per_page: per_page,
        sort_by: sort_by,
        sort_dir: sort_dir,
        brand_id: brand_id,
        period: time_preset
      ]
      |> maybe_add_opt(:search_query, search_query)
      |> maybe_add_opt(:creator_id, creator_id)
      |> maybe_add_opt(:min_gmv, min_gmv)

    result = Creators.search_videos_paginated(opts)

    socket
    |> assign(:loading_videos, false)
    |> assign(:videos, socket.assigns.videos ++ result.videos)
    |> assign(:has_more, result.has_more)
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, _key, ""), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp build_query_params(socket, overrides) do
    base = %{
      q: socket.assigns.search_query,
      sort: "#{socket.assigns.sort_by}_#{socket.assigns.sort_dir}",
      page: socket.assigns.page,
      creator: socket.assigns.selected_creator_id,
      period: socket.assigns.time_preset,
      min_gmv: socket.assigns.min_gmv
    }

    overrides
    |> Enum.reduce(base, fn {key, value}, acc ->
      case key do
        :sort_by ->
          dir = Keyword.get(overrides, :sort_dir, socket.assigns.sort_dir)
          Map.put(acc, :sort, "#{value}_#{dir}")

        :sort_dir ->
          by = Keyword.get(overrides, :sort_by, socket.assigns.sort_by)
          Map.put(acc, :sort, "#{by}_#{value}")

        :search_query ->
          Map.put(acc, :q, value)

        :selected_creator_id ->
          Map.put(acc, :creator, value)

        :page ->
          Map.put(acc, :page, value)

        :time_preset ->
          Map.put(acc, :period, value)

        :min_gmv ->
          Map.put(acc, :min_gmv, value)

        _ ->
          acc
      end
    end)
    |> reject_default_values()
  end

  defp reject_default_values(params) do
    params
    |> Enum.reject(&default_value?/1)
    |> Map.new()
  end

  defp default_value?({_k, ""}), do: true
  defp default_value?({_k, nil}), do: true
  defp default_value?({:page, 1}), do: true
  defp default_value?({:sort, "gmv_desc"}), do: true
  defp default_value?({:period, "all"}), do: true
  defp default_value?(_), do: false

  # Time preset validation and conversion
  defp validate_time_preset(preset) when preset in ["30", "90", "all"], do: preset
  defp validate_time_preset(_), do: "all"

  # Min GMV validation - only allow specific preset values (stored in cents)
  @valid_min_gmv_values [50_000, 100_000, 500_000]

  defp parse_min_gmv(""), do: nil
  defp parse_min_gmv(nil), do: nil

  defp parse_min_gmv(amount) when is_binary(amount) do
    case Integer.parse(amount) do
      {num, ""} when num in @valid_min_gmv_values -> num
      _ -> nil
    end
  end

  defp parse_min_gmv(amount) when amount in @valid_min_gmv_values, do: amount
  defp parse_min_gmv(_), do: nil

  defp normalize_min_gmv("gmv", _min_gmv), do: nil
  defp normalize_min_gmv(_sort_by, nil), do: @default_min_gmv
  defp normalize_min_gmv(_sort_by, min_gmv), do: min_gmv
end
