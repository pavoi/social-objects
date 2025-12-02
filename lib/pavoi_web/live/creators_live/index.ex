defmodule PavoiWeb.CreatorsLive.Index do
  @moduledoc """
  LiveView for the creator CRM list view.

  Displays a paginated, searchable, filterable table of creators.
  """
  use PavoiWeb, :live_view

  on_mount {PavoiWeb.NavHooks, :set_current_page}

  alias Pavoi.Catalog
  alias Pavoi.Creators

  import PavoiWeb.CreatorComponents

  @impl true
  def mount(_params, _session, socket) do
    brands = Catalog.list_brands()

    socket =
      socket
      |> assign(:creators, [])
      |> assign(:search_query, "")
      |> assign(:badge_filter, "")
      |> assign(:brand_filter, "")
      |> assign(:sort_by, nil)
      |> assign(:sort_dir, "asc")
      |> assign(:page, 1)
      |> assign(:per_page, 50)
      |> assign(:total, 0)
      |> assign(:has_more, false)
      |> assign(:loading, false)
      |> assign(:brands, brands)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> apply_params(params)
      |> load_creators()

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"value" => query}, socket) do
    params = build_query_params(socket, search_query: query, page: 1)
    {:noreply, push_patch(socket, to: ~p"/creators?#{params}")}
  end

  @impl true
  def handle_event("filter_badge", %{"badge" => badge}, socket) do
    params = build_query_params(socket, badge_filter: badge, page: 1)
    {:noreply, push_patch(socket, to: ~p"/creators?#{params}")}
  end

  @impl true
  def handle_event("filter_brand", %{"brand" => brand}, socket) do
    params = build_query_params(socket, brand_filter: brand, page: 1)
    {:noreply, push_patch(socket, to: ~p"/creators?#{params}")}
  end

  @impl true
  def handle_event("sort_column", %{"field" => field, "dir" => dir}, socket) do
    params = build_query_params(socket, sort_by: field, sort_dir: dir, page: 1)
    {:noreply, push_patch(socket, to: ~p"/creators?#{params}")}
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    params = build_query_params(socket, page: socket.assigns.page + 1)
    {:noreply, push_patch(socket, to: ~p"/creators?#{params}")}
  end

  @impl true
  def handle_event("navigate_to_creator", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/creators/#{id}")}
  end

  @impl true
  def handle_event("stop_propagation", _params, socket) do
    {:noreply, socket}
  end

  defp apply_params(socket, params) do
    socket
    |> assign(:search_query, params["q"] || "")
    |> assign(:badge_filter, params["badge"] || "")
    |> assign(:brand_filter, params["brand"] || "")
    |> assign(:sort_by, params["sort"])
    |> assign(:sort_dir, params["dir"] || "asc")
    |> assign(:page, parse_page(params["page"]))
  end

  defp parse_page(nil), do: 1
  defp parse_page(page) when is_binary(page), do: String.to_integer(page)
  defp parse_page(page) when is_integer(page), do: page

  defp load_creators(socket) do
    %{
      search_query: search_query,
      badge_filter: badge_filter,
      brand_filter: brand_filter,
      sort_by: sort_by,
      sort_dir: sort_dir,
      page: page,
      per_page: per_page
    } = socket.assigns

    opts =
      [page: page, per_page: per_page]
      |> maybe_add_opt(:search_query, search_query)
      |> maybe_add_opt(:badge_level, badge_filter)
      |> maybe_add_opt(:brand_id, parse_brand_id(brand_filter))
      |> maybe_add_opt(:sort_by, sort_by)
      |> maybe_add_opt(:sort_dir, sort_dir)

    result = Creators.search_creators_paginated(opts)

    # Add sample counts to each creator
    creators_with_counts =
      Enum.map(result.creators, fn creator ->
        sample_count = Creators.count_samples_for_creator(creator.id)
        Map.put(creator, :sample_count, sample_count)
      end)

    # If loading more (page > 1), append to existing
    creators =
      if page > 1 do
        socket.assigns.creators ++ creators_with_counts
      else
        creators_with_counts
      end

    socket
    |> assign(:creators, creators)
    |> assign(:total, result.total)
    |> assign(:has_more, result.has_more)
    |> assign(:loading, false)
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, _key, ""), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_brand_id(""), do: nil
  defp parse_brand_id(nil), do: nil
  defp parse_brand_id(id) when is_binary(id), do: String.to_integer(id)
  defp parse_brand_id(id), do: id

  defp build_query_params(socket, overrides) do
    base = %{
      q: socket.assigns.search_query,
      badge: socket.assigns.badge_filter,
      brand: socket.assigns.brand_filter,
      sort: socket.assigns.sort_by,
      dir: socket.assigns.sort_dir,
      page: socket.assigns.page
    }

    merged =
      Enum.reduce(overrides, base, fn
        {:search_query, v}, acc -> Map.put(acc, :q, v)
        {:badge_filter, v}, acc -> Map.put(acc, :badge, v)
        {:brand_filter, v}, acc -> Map.put(acc, :brand, v)
        {:sort_by, v}, acc -> Map.put(acc, :sort, v)
        {:sort_dir, v}, acc -> Map.put(acc, :dir, v)
        {:page, v}, acc -> Map.put(acc, :page, v)
      end)

    # Remove empty/default values and page=1
    merged
    |> Enum.reject(fn {k, v} ->
      v == "" || v == nil || (k == :page && v == 1) || (k == :dir && v == "asc")
    end)
    |> Map.new()
  end
end
