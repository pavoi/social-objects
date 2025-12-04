defmodule PavoiWeb.CreatorsLive.Index do
  @moduledoc """
  LiveView for the creator CRM list view.

  Displays a paginated, searchable, filterable table of creators.
  Modal overlay for creator details with tabbed interface.
  """
  use PavoiWeb, :live_view

  import Ecto.Query

  on_mount {PavoiWeb.NavHooks, :set_current_page}

  alias Pavoi.Creators
  alias Pavoi.Creators.Creator
  alias Pavoi.Settings
  alias Pavoi.Workers.BigQueryOrderSyncWorker

  import PavoiWeb.CreatorComponents

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to BigQuery sync events
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Pavoi.PubSub, "bigquery:sync")
    end

    bigquery_last_sync_at = Settings.get_bigquery_last_sync_at()
    bigquery_syncing = sync_job_active?(BigQueryOrderSyncWorker)

    socket =
      socket
      |> assign(:creators, [])
      |> assign(:search_query, "")
      |> assign(:badge_filter, "")
      |> assign(:sort_by, "gmv")
      |> assign(:sort_dir, "desc")
      |> assign(:page, 1)
      |> assign(:per_page, 50)
      |> assign(:total, 0)
      |> assign(:has_more, false)
      |> assign(:loading_creators, false)
      # Modal state
      |> assign(:selected_creator, nil)
      |> assign(:active_tab, "contact")
      |> assign(:editing_contact, false)
      |> assign(:contact_form, nil)
      # Sync state
      |> assign(:bigquery_syncing, bigquery_syncing)
      |> assign(:bigquery_last_sync_at, bigquery_last_sync_at)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> apply_params(params)
      |> load_creators()
      |> maybe_load_selected_creator(params)

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
  def handle_event("sort_column", %{"field" => field, "dir" => dir}, socket) do
    params = build_query_params(socket, sort_by: field, sort_dir: dir, page: 1)
    {:noreply, push_patch(socket, to: ~p"/creators?#{params}")}
  end

  @impl true
  def handle_event("navigate_to_creator", %{"id" => id}, socket) do
    params = build_query_params(socket, creator_id: id)
    {:noreply, push_patch(socket, to: ~p"/creators?#{params}")}
  end

  @impl true
  def handle_event("close_creator_modal", _params, socket) do
    params = build_query_params(socket, creator_id: nil, tab: nil)

    socket =
      socket
      |> assign(:selected_creator, nil)
      |> assign(:active_tab, "contact")
      |> assign(:editing_contact, false)
      |> assign(:contact_form, nil)
      |> push_patch(to: ~p"/creators?#{params}")

    {:noreply, socket}
  end

  @impl true
  def handle_event("change_tab", %{"tab" => tab}, socket) do
    params = build_query_params(socket, tab: tab)
    {:noreply, push_patch(socket, to: ~p"/creators?#{params}")}
  end

  @impl true
  def handle_event("edit_contact", _params, socket) do
    form =
      socket.assigns.selected_creator
      |> Creator.changeset(%{})
      |> to_form()

    socket =
      socket
      |> assign(:editing_contact, true)
      |> assign(:contact_form, form)

    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    socket =
      socket
      |> assign(:editing_contact, false)
      |> assign(:contact_form, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("validate_contact", %{"creator" => params}, socket) do
    changeset =
      socket.assigns.selected_creator
      |> Creator.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :contact_form, to_form(changeset))}
  end

  @impl true
  def handle_event("save_contact", %{"creator" => params}, socket) do
    case Creators.update_creator(socket.assigns.selected_creator, params) do
      {:ok, creator} ->
        # Reload with associations
        creator = Creators.get_creator_with_details!(creator.id)

        socket =
          socket
          |> assign(:selected_creator, creator)
          |> assign(:editing_contact, false)
          |> assign(:contact_form, nil)
          |> put_flash(:info, "Contact info updated")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :contact_form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("stop_propagation", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("trigger_bigquery_sync", _params, socket) do
    %{}
    |> BigQueryOrderSyncWorker.new()
    |> Oban.insert()

    socket =
      socket
      |> assign(:bigquery_syncing, true)
      |> put_flash(:info, "BigQuery orders sync initiated...")

    {:noreply, socket}
  end

  # =============================================================================
  # INFINITE SCROLL IMPLEMENTATION
  # =============================================================================
  #
  # Why this uses send(self(), ...) instead of loading directly:
  #
  # The template uses: phx-viewport-bottom={@has_more && !@loading_creators && "load_more"}
  #
  # WRONG approach (causes infinite loop):
  #   def handle_event("load_more", _params, socket) do
  #     socket
  #     |> assign(:loading_creators, true)   # Set loading
  #     |> assign(:page, socket.assigns.page + 1)
  #     |> load_creators()                   # This sets loading_creators back to false!
  #     |> then(&{:noreply, &1})
  #   end
  #
  # Problem: LiveView only sends ONE diff to the client - the FINAL state.
  # The client never sees loading_creators=true, only the final loading_creators=false.
  # So the phx-viewport-bottom binding remains active, fires again, infinite loop.
  #
  # CORRECT approach (two-phase update):
  #   1. handle_event sets loading_creators=true and returns immediately
  #   2. Client receives diff with loading_creators=true → binding disabled
  #   3. handle_info loads data and sets loading_creators=false
  #   4. Client receives new data → user scrolls to see it → no longer at bottom
  #
  # =============================================================================

  @impl true
  def handle_event("load_more", _params, socket) do
    # Phase 1: Disable the viewport binding immediately by setting loading=true
    # The actual data loading happens in handle_info (Phase 2)
    send(self(), :load_more_creators)
    {:noreply, assign(socket, :loading_creators, true)}
  end

  # BigQuery sync PubSub handlers
  @impl true
  def handle_info({:bigquery_sync_started}, socket) do
    {:noreply, assign(socket, :bigquery_syncing, true)}
  end

  @impl true
  def handle_info({:bigquery_sync_completed, stats}, socket) do
    socket =
      socket
      |> assign(:bigquery_syncing, false)
      |> assign(:bigquery_last_sync_at, Settings.get_bigquery_last_sync_at())
      |> assign(:page, 1)
      |> load_creators()
      |> put_flash(
        :info,
        "Synced #{stats.samples_created} samples (#{stats.creators_created} new creators, #{stats.creators_matched} matched)"
      )

    {:noreply, socket}
  end

  @impl true
  def handle_info({:bigquery_sync_failed, reason}, socket) do
    socket =
      socket
      |> assign(:bigquery_syncing, false)
      |> put_flash(:error, "BigQuery sync failed: #{inspect(reason)}")

    {:noreply, socket}
  end

  # Infinite scroll Phase 2 - see comment block above handle_event("load_more", ...)
  @impl true
  def handle_info(:load_more_creators, socket) do
    socket =
      socket
      |> assign(:page, socket.assigns.page + 1)
      |> load_creators()

    {:noreply, socket}
  end

  defp sync_job_active?(worker) do
    from(j in Oban.Job,
      where: j.worker == ^to_string(worker),
      where: j.state in ["executing", "available", "scheduled"]
    )
    |> Pavoi.Repo.exists?()
  end

  defp apply_params(socket, params) do
    socket
    |> assign(:search_query, params["q"] || "")
    |> assign(:badge_filter, params["badge"] || "")
    |> assign(:sort_by, params["sort"] || "gmv")
    |> assign(:sort_dir, params["dir"] || "desc")
    |> assign(:page, parse_page(params["page"]))
  end

  defp parse_page(nil), do: 1
  defp parse_page(page) when is_binary(page), do: String.to_integer(page)
  defp parse_page(page) when is_integer(page), do: page

  defp load_creators(socket) do
    %{
      search_query: search_query,
      badge_filter: badge_filter,
      sort_by: sort_by,
      sort_dir: sort_dir,
      page: page,
      per_page: per_page
    } = socket.assigns

    opts =
      [page: page, per_page: per_page]
      |> maybe_add_opt(:search_query, search_query)
      |> maybe_add_opt(:badge_level, badge_filter)
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
    |> assign(:loading_creators, false)
    |> assign(:creators, creators)
    |> assign(:total, result.total)
    |> assign(:has_more, result.has_more)
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, _key, ""), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  @override_key_mapping %{
    search_query: :q,
    badge_filter: :badge,
    sort_by: :sort,
    sort_dir: :dir,
    page: :page,
    creator_id: :c,
    tab: :tab
  }

  defp build_query_params(socket, overrides) do
    base = %{
      q: socket.assigns.search_query,
      badge: socket.assigns.badge_filter,
      sort: socket.assigns.sort_by,
      dir: socket.assigns.sort_dir,
      page: socket.assigns.page,
      c: get_creator_id(socket.assigns.selected_creator),
      tab: socket.assigns.active_tab
    }

    overrides
    |> Enum.reduce(base, fn {key, value}, acc ->
      Map.put(acc, Map.fetch!(@override_key_mapping, key), value)
    end)
    |> reject_default_values()
  end

  defp get_creator_id(nil), do: nil
  defp get_creator_id(creator), do: creator.id

  defp reject_default_values(params) do
    params
    |> Enum.reject(&default_value?/1)
    |> Map.new()
  end

  defp default_value?({_k, ""}), do: true
  defp default_value?({_k, nil}), do: true
  defp default_value?({:page, 1}), do: true
  defp default_value?({:sort, "gmv"}), do: true
  defp default_value?({:dir, "desc"}), do: true
  defp default_value?({:tab, "contact"}), do: true
  defp default_value?(_), do: false

  defp maybe_load_selected_creator(socket, params) do
    case params["c"] do
      nil ->
        socket
        |> assign(:selected_creator, nil)
        |> assign(:active_tab, "contact")
        |> assign(:editing_contact, false)
        |> assign(:contact_form, nil)

      creator_id ->
        creator = Creators.get_creator_with_details!(creator_id)
        tab = params["tab"] || "contact"

        socket
        |> assign(:selected_creator, creator)
        |> assign(:active_tab, tab)
    end
  end
end
