defmodule PavoiWeb.VideosLive.Index do
  @moduledoc """
  LiveView for browsing affiliate video performance.

  Displays a paginated, searchable, filterable grid of creator videos.
  """
  use PavoiWeb, :live_view

  on_mount {PavoiWeb.NavHooks, :set_current_page}

  alias Pavoi.Creators
  alias PavoiWeb.BrandRoutes

  import PavoiWeb.VideoComponents
  import PavoiWeb.ViewHelpers

  @impl true
  def mount(_params, _session, socket) do
    brand_id = socket.assigns.current_brand.id

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
      |> assign(:available_creators, [])
      |> assign(:brand_id, brand_id)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> apply_params(params)
      |> load_videos()

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"value" => query}, socket) do
    params = build_query_params(socket, search_query: query, page: 1)
    {:noreply, push_patch(socket, to: videos_path(socket, params))}
  end

  @impl true
  def handle_event("sort_videos", %{"sort" => sort_value}, socket) do
    {sort_by, sort_dir} = parse_sort(sort_value)
    params = build_query_params(socket, sort_by: sort_by, sort_dir: sort_dir, page: 1)
    {:noreply, push_patch(socket, to: videos_path(socket, params))}
  end

  @impl true
  def handle_event("toggle_sort_dir", _params, socket) do
    new_dir = if socket.assigns.sort_dir == "desc", do: "asc", else: "desc"
    params = build_query_params(socket, sort_dir: new_dir, page: 1)
    {:noreply, push_patch(socket, to: videos_path(socket, params))}
  end

  @impl true
  def handle_event("filter_creator", %{"creator_id" => creator_id}, socket) do
    creator_id = if creator_id == "", do: nil, else: String.to_integer(creator_id)
    params = build_query_params(socket, selected_creator_id: creator_id, page: 1)
    {:noreply, push_patch(socket, to: videos_path(socket, params))}
  end

  @impl true
  def handle_event("open_video", %{"id" => id}, socket) do
    video = Enum.find(socket.assigns.videos, &(&1.id == String.to_integer(id)))

    if video do
      url = build_tiktok_url(video)
      {:noreply, redirect(socket, external: url)}
    else
      {:noreply, put_flash(socket, :error, "Could not open video")}
    end
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    send(self(), :load_more_videos)
    {:noreply, assign(socket, :loading_videos, true)}
  end

  @impl true
  def handle_info(:load_more_videos, socket) do
    socket =
      socket
      |> assign(:page, socket.assigns.page + 1)
      |> load_more_videos()

    {:noreply, socket}
  end

  # Private functions

  defp build_tiktok_url(video) do
    if video.video_url && video.video_url != "" do
      video.video_url
    else
      username = video.creator && video.creator.tiktok_username
      "https://www.tiktok.com/@#{username || "unknown"}/video/#{video.tiktok_video_id}"
    end
  end

  defp videos_path(socket, params) when is_map(params) do
    query = URI.encode_query(params)
    path = if query == "", do: "/videos", else: "/videos?#{query}"
    BrandRoutes.brand_path(socket.assigns.current_brand, path, socket.assigns.current_host)
  end

  defp apply_params(socket, params) do
    {sort_by, sort_dir} = parse_sort(params["sort"])

    socket
    |> assign(:search_query, params["q"] || "")
    |> assign(:sort_by, sort_by)
    |> assign(:sort_dir, sort_dir)
    |> assign(:page, parse_page(params["page"]))
    |> assign(:selected_creator_id, parse_creator_id(params["creator"]))
  end

  defp parse_sort(nil), do: {"gmv", "desc"}
  defp parse_sort(""), do: {"gmv", "desc"}

  defp parse_sort(sort) do
    case String.split(sort, "_", parts: 2) do
      [field, dir] when dir in ["asc", "desc"] -> {field, dir}
      [field] -> {field, "desc"}
      _ -> {"gmv", "desc"}
    end
  end

  defp parse_page(nil), do: 1
  defp parse_page(""), do: 1
  defp parse_page(page) when is_binary(page), do: String.to_integer(page)
  defp parse_page(page) when is_integer(page), do: page

  defp parse_creator_id(nil), do: nil
  defp parse_creator_id(""), do: nil
  defp parse_creator_id(id) when is_binary(id), do: String.to_integer(id)

  defp load_videos(socket) do
    %{
      search_query: search_query,
      sort_by: sort_by,
      sort_dir: sort_dir,
      per_page: per_page,
      selected_creator_id: creator_id,
      brand_id: brand_id
    } = socket.assigns

    opts =
      [
        page: 1,
        per_page: per_page,
        sort_by: sort_by,
        sort_dir: sort_dir,
        brand_id: brand_id
      ]
      |> maybe_add_opt(:search_query, search_query)
      |> maybe_add_opt(:creator_id, creator_id)

    result = Creators.search_videos_paginated(opts)

    # Load distinct creators for filter dropdown
    available_creators = Creators.list_creators_with_videos(brand_id)

    socket
    |> assign(:loading_videos, false)
    |> assign(:videos, result.videos)
    |> assign(:total, result.total)
    |> assign(:has_more, result.has_more)
    |> assign(:page, 1)
    |> assign(:available_creators, available_creators)
  end

  defp load_more_videos(socket) do
    %{
      search_query: search_query,
      sort_by: sort_by,
      sort_dir: sort_dir,
      page: page,
      per_page: per_page,
      selected_creator_id: creator_id,
      brand_id: brand_id
    } = socket.assigns

    opts =
      [
        page: page,
        per_page: per_page,
        sort_by: sort_by,
        sort_dir: sort_dir,
        brand_id: brand_id
      ]
      |> maybe_add_opt(:search_query, search_query)
      |> maybe_add_opt(:creator_id, creator_id)

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
      creator: socket.assigns.selected_creator_id
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
  defp default_value?(_), do: false
end
