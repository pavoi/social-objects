defmodule PavoiWeb.CreatorsLive.Index do
  @moduledoc """
  LiveView for the creator CRM list view.

  Displays a paginated, searchable, filterable table of creators.
  Modal overlay for creator details with tabbed interface.
  """
  use PavoiWeb, :live_view

  import Ecto.Query

  on_mount {PavoiWeb.NavHooks, :set_current_page}

  alias Pavoi.Catalog
  alias Pavoi.Creators
  alias Pavoi.Creators.Creator
  alias Pavoi.Outreach
  alias Pavoi.Settings
  alias Pavoi.Workers.BigQueryOrderSyncWorker
  alias Pavoi.Workers.CreatorEnrichmentWorker
  alias Pavoi.Workers.CreatorOutreachWorker

  import PavoiWeb.CreatorComponents
  import PavoiWeb.ViewHelpers

  @sync_job_stale_after_seconds 30 * 60
  @tag_colors ~w(amber blue green red purple gray)

  # Lark community invite link presets
  @lark_presets %{
    jewelry: %{
      key: "lark_preset_jewelry",
      label: "Jewelry",
      default_url:
        "https://applink.larksuite.com/client/chat/chatter/add_by_link?link_token=381ve559-aa4d-4a1d-9412-6bee35821e1i"
    },
    active: %{
      key: "lark_preset_active",
      label: "Active",
      default_url:
        "https://applink.larksuite.com/client/chat/chatter/add_by_link?link_token=308u55cf-7f36-4516-a0b7-a102361a1c2n"
    },
    top_creators: %{
      key: "lark_preset_top_creators",
      label: "Top Creators",
      default_url:
        "https://applink.larksuite.com/client/chat/chatter/add_by_link?link_token=3c9q707a-24bf-449a-9ee9-aef46e73e7es"
    }
  }

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to BigQuery sync, enrichment, and outreach events
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Pavoi.PubSub, "bigquery:sync")
      Phoenix.PubSub.subscribe(Pavoi.PubSub, "creator:enrichment")
      Phoenix.PubSub.subscribe(Pavoi.PubSub, "outreach:updates")
    end

    bigquery_last_sync_at = Settings.get_bigquery_last_sync_at()
    bigquery_syncing = sync_job_active?(BigQueryOrderSyncWorker)
    enrichment_last_sync_at = Settings.get_enrichment_last_sync_at()
    enrichment_syncing = sync_job_active?(CreatorEnrichmentWorker)
    features = Application.get_env(:pavoi, :features, [])

    # Get the PAVOI brand for tag operations
    pavoi_brand = Catalog.get_brand_by_slug("pavoi")
    brand_id = if pavoi_brand, do: pavoi_brand.id, else: nil
    available_tags = if brand_id, do: Creators.list_tags_for_brand(brand_id), else: []

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
      # Lazy-loaded modal tab data
      |> assign(:modal_samples, nil)
      |> assign(:modal_videos, nil)
      |> assign(:modal_performance, nil)
      |> assign(:modal_fulfillment_stats, nil)
      |> assign(:refreshing, false)
      # Unified creators state (merged CRM + Outreach)
      |> assign(:outreach_status, nil)
      |> assign(:selected_ids, MapSet.new())
      |> assign(:show_status_filter, false)
      |> assign(:all_selected_pending, false)
      |> assign(:outreach_stats, %{pending: 0, sent: 0, skipped: 0})
      |> assign(:sent_today, 0)
      |> assign(:lark_presets, %{})
      |> assign(:selected_lark_preset, :jewelry)
      |> assign(:lark_edit_mode, false)
      |> assign(:lark_edit_form, %{})
      |> assign(:outreach_email_override, Keyword.get(features, :outreach_email_override))
      |> assign(:outreach_email_enabled, Keyword.get(features, :outreach_email_enabled, true))
      |> assign(:show_send_modal, false)
      # Sync state
      |> assign(:bigquery_syncing, bigquery_syncing)
      |> assign(:bigquery_last_sync_at, bigquery_last_sync_at)
      |> assign(:enrichment_syncing, enrichment_syncing)
      |> assign(:enrichment_last_sync_at, enrichment_last_sync_at)
      # Tag state
      |> assign(:brand_id, brand_id)
      |> assign(:available_tags, available_tags)
      |> assign(:filter_tag_ids, [])
      |> assign(:tag_picker_open_for, nil)
      |> assign(:tag_picker_source, nil)
      |> assign(:tag_search_query, "")
      |> assign(:new_tag_color, "gray")
      |> assign(:show_tag_filter, false)
      |> assign(:show_batch_tag_picker, false)
      |> assign(:picker_selected_tag_ids, [])
      |> assign(:batch_selected_tag_ids, [])
      # Time filter state
      |> assign(:added_after, nil)
      |> assign(:added_before, nil)
      |> assign(:show_time_filter, false)
      # Data freshness state
      |> assign(:videos_last_import_at, Settings.get_videos_last_import_at())

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> apply_params(params)
      |> load_creators()
      |> load_outreach_stats()
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
    # Ignore close if tag picker is open from modal (triggered by click-away on picker)
    if socket.assigns.tag_picker_open_for && socket.assigns.tag_picker_source == :modal do
      {:noreply, socket}
    else
      params = build_query_params(socket, creator_id: nil, tab: nil)

      socket =
        socket
        |> assign(:selected_creator, nil)
        |> assign(:active_tab, "contact")
        |> assign(:editing_contact, false)
        |> assign(:contact_form, nil)
        |> assign(:tag_picker_open_for, nil)
        |> assign(:tag_picker_source, nil)
        |> push_patch(to: ~p"/creators?#{params}")

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("change_tab", %{"tab" => tab}, socket) do
    # Load tab data if switching to a tab that needs it
    socket =
      if socket.assigns.selected_creator do
        load_modal_tab_data(socket, tab, socket.assigns.selected_creator.id)
      else
        socket
      end

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
        # Reload with minimal associations (not all tab data)
        creator = Creators.get_creator_for_modal!(creator.id)

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
    {:noreply,
     enqueue_sync_job(
       socket,
       BigQueryOrderSyncWorker,
       %{"source" => "manual"},
       :bigquery_syncing,
       "BigQuery orders sync initiated..."
     )}
  end

  @impl true
  def handle_event("trigger_enrichment_sync", _params, socket) do
    {:noreply,
     enqueue_sync_job(
       socket,
       CreatorEnrichmentWorker,
       %{"source" => "manual"},
       :enrichment_syncing,
       "Creator enrichment started..."
     )}
  end

  @impl true
  def handle_event("refresh_creator_data", %{"id" => id}, socket) do
    # Phase 1: Set refreshing state immediately and return
    # The actual refresh happens in handle_info (Phase 2)
    # This ensures the UI updates before the slow operation starts
    send(self(), {:refresh_creator_data, id})
    {:noreply, assign(socket, :refreshing, true)}
  end

  # Status filter event handlers
  @impl true
  def handle_event("toggle_status_filter", _params, socket) do
    {:noreply, assign(socket, :show_status_filter, !socket.assigns.show_status_filter)}
  end

  @impl true
  def handle_event("close_status_filter", _params, socket) do
    {:noreply, assign(socket, :show_status_filter, false)}
  end

  @impl true
  def handle_event("clear_status_filter", _params, socket) do
    socket = assign(socket, :show_status_filter, false)
    params = build_query_params(socket, outreach_status: nil, page: 1)
    {:noreply, push_patch(socket, to: ~p"/creators?#{params}")}
  end

  @impl true
  def handle_event("change_outreach_status", %{"status" => status}, socket) do
    # Convert empty string to nil (meaning "all")
    status = if status == "", do: nil, else: status
    socket = assign(socket, :show_status_filter, false)
    params = build_query_params(socket, outreach_status: status, page: 1)
    {:noreply, push_patch(socket, to: ~p"/creators?#{params}")}
  end

  @impl true
  def handle_event("toggle_selection", %{"id" => id}, socket) do
    id = String.to_integer(id)
    selected = socket.assigns.selected_ids

    selected =
      if MapSet.member?(selected, id) do
        MapSet.delete(selected, id)
      else
        MapSet.put(selected, id)
      end

    socket =
      socket
      |> assign(:selected_ids, selected)
      |> compute_all_selected_pending()

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_all", _params, socket) do
    all_ids = Enum.map(socket.assigns.creators, & &1.id) |> MapSet.new()

    socket =
      socket
      |> assign(:selected_ids, all_ids)
      |> compute_all_selected_pending()

    {:noreply, socket}
  end

  @impl true
  def handle_event("deselect_all", _params, socket) do
    socket =
      socket
      |> assign(:selected_ids, MapSet.new())
      |> assign(:all_selected_pending, false)

    {:noreply, socket}
  end

  @impl true
  def handle_event("show_send_modal", _params, socket) do
    if MapSet.size(socket.assigns.selected_ids) > 0 do
      {:noreply, assign(socket, :show_send_modal, true)}
    else
      {:noreply, put_flash(socket, :error, "Please select at least one creator")}
    end
  end

  @impl true
  def handle_event("close_send_modal", _params, socket) do
    {:noreply, assign(socket, :show_send_modal, false)}
  end

  @impl true
  def handle_event("select_lark_preset", %{"preset" => preset_id}, socket) do
    preset_atom = String.to_existing_atom(preset_id)
    {:noreply, assign(socket, :selected_lark_preset, preset_atom)}
  end

  @impl true
  def handle_event("toggle_lark_edit_mode", _params, socket) do
    if socket.assigns.lark_edit_mode do
      # Exiting edit mode - discard changes
      {:noreply,
       socket
       |> assign(:lark_edit_mode, false)
       |> assign(:lark_edit_form, %{})}
    else
      # Entering edit mode - initialize form with current values
      edit_form =
        socket.assigns.lark_presets
        |> Enum.map(fn {id, preset} -> {id, preset.url} end)
        |> Map.new()

      {:noreply,
       socket
       |> assign(:lark_edit_mode, true)
       |> assign(:lark_edit_form, edit_form)}
    end
  end

  @impl true
  def handle_event("update_lark_preset_url", %{"preset" => preset_id, "url" => url}, socket) do
    preset_atom = String.to_existing_atom(preset_id)
    edit_form = Map.put(socket.assigns.lark_edit_form, preset_atom, url)
    {:noreply, assign(socket, :lark_edit_form, edit_form)}
  end

  @impl true
  def handle_event("save_lark_presets", _params, socket) do
    # Persist each edited URL to settings
    Enum.each(socket.assigns.lark_edit_form, fn {preset_id, url} ->
      key = @lark_presets[preset_id].key
      Settings.set_setting(key, String.trim(url))
    end)

    # Reload presets and exit edit mode
    {:noreply,
     socket
     |> assign(:lark_presets, load_lark_presets())
     |> assign(:lark_edit_mode, false)
     |> assign(:lark_edit_form, %{})
     |> put_flash(:info, "Lark presets updated")}
  end

  @impl true
  def handle_event("cancel_lark_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:lark_edit_mode, false)
     |> assign(:lark_edit_form, %{})}
  end

  @impl true
  def handle_event("send_outreach", _params, socket) do
    selected_preset = socket.assigns.selected_lark_preset
    lark_url = socket.assigns.lark_presets[selected_preset].url

    if String.trim(lark_url) == "" do
      {:noreply, put_flash(socket, :error, "Selected Lark group has no URL configured")}
    else
      creator_ids = MapSet.to_list(socket.assigns.selected_ids)
      # Pass the preset name (e.g., "jewelry") instead of the URL
      # The worker generates a join token URL for emails
      lark_preset = Atom.to_string(selected_preset)
      {:ok, count} = CreatorOutreachWorker.enqueue_batch(creator_ids, lark_preset)

      socket =
        socket
        |> assign(:show_send_modal, false)
        |> assign(:selected_ids, MapSet.new())
        |> assign(:all_selected_pending, false)
        |> put_flash(:info, "Queued #{count} outreach messages for sending")
        |> push_patch(to: ~p"/creators?status=sent")

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("skip_selected", _params, socket) do
    creator_ids = MapSet.to_list(socket.assigns.selected_ids)

    if length(creator_ids) > 0 do
      count = Outreach.mark_creators_skipped(creator_ids)

      socket =
        socket
        |> assign(:selected_ids, MapSet.new())
        |> assign(:page, 1)
        |> put_flash(:info, "Skipped #{count} creators")
        |> load_creators()
        |> load_outreach_stats()

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, "Please select at least one creator")}
    end
  end

  # =============================================================================
  # TAG MANAGEMENT EVENT HANDLERS
  # =============================================================================

  @impl true
  def handle_event("open_tag_picker", %{"creator-id" => creator_id}, socket) do
    creator_id = String.to_integer(creator_id)
    selected_tag_ids = Creators.get_tag_ids_for_creator(creator_id)
    random_color = Enum.random(@tag_colors)

    socket =
      socket
      |> assign(:tag_picker_open_for, creator_id)
      |> assign(:tag_picker_source, :table)
      |> assign(:tag_search_query, "")
      |> assign(:creating_tag, false)
      |> assign(:new_tag_color, random_color)
      |> assign(:picker_selected_tag_ids, selected_tag_ids)

    {:noreply, socket}
  end

  @impl true
  def handle_event("open_modal_tag_picker", _params, socket) do
    creator = socket.assigns.selected_creator

    if creator do
      selected_tag_ids = Creators.get_tag_ids_for_creator(creator.id)
      random_color = Enum.random(@tag_colors)

      socket =
        socket
        |> assign(:tag_picker_open_for, creator.id)
        |> assign(:tag_picker_source, :modal)
        |> assign(:tag_search_query, "")
        |> assign(:creating_tag, false)
        |> assign(:new_tag_color, random_color)
        |> assign(:picker_selected_tag_ids, selected_tag_ids)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_tag_picker", params, socket) do
    force = params["force"] == true

    # When opened from modal, ignore click-outside closes to prevent race with modal click-away
    # User can force close via Escape key
    if socket.assigns.tag_picker_source == :modal && !force do
      {:noreply, socket}
    else
      socket =
        socket
        |> assign(:tag_picker_open_for, nil)
        |> assign(:tag_picker_source, nil)
        |> assign(:tag_search_query, "")

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("noop", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("search_tags", %{"value" => query}, socket) do
    {:noreply, assign(socket, :tag_search_query, query)}
  end

  @impl true
  def handle_event("tag_picker_enter", _params, socket) do
    query = String.trim(socket.assigns.tag_search_query || "")
    creator_id = socket.assigns.tag_picker_open_for

    # Only create if there's text and no exact match exists
    if query != "" && creator_id do
      available_tags = socket.assigns.available_tags

      exact_match =
        Enum.find(available_tags, fn tag ->
          String.downcase(tag.name) == String.downcase(query)
        end)

      if exact_match do
        # If exact match exists, assign that tag
        Creators.assign_tag_to_creator(creator_id, exact_match.id)
        selected_tag_ids = [exact_match.id | socket.assigns[:picker_selected_tag_ids] || []]

        socket =
          socket
          |> assign(:tag_search_query, "")
          |> assign(:picker_selected_tag_ids, Enum.uniq(selected_tag_ids))
          |> reload_creator_tags(creator_id)
          |> maybe_refresh_selected_creator_tags(creator_id)
          |> assign(:tag_picker_open_for, nil)
          |> assign(:tag_picker_source, nil)

        {:noreply, socket}
      else
        # Create new tag - reuse quick_create_tag logic
        params = %{
          "name" => query,
          "creator-id" => to_string(creator_id),
          "color" => socket.assigns.new_tag_color
        }

        handle_event("quick_create_tag", params, socket)
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_tag", %{"creator-id" => creator_id, "tag-id" => tag_id}, socket) do
    creator_id = String.to_integer(creator_id)
    selected_tag_ids = socket.assigns[:picker_selected_tag_ids] || []
    _from_modal = socket.assigns.tag_picker_source == :modal

    # Update the tag assignment
    new_selected_tag_ids =
      if tag_id in selected_tag_ids do
        Creators.remove_tag_from_creator(creator_id, tag_id)
        List.delete(selected_tag_ids, tag_id)
      else
        Creators.assign_tag_to_creator(creator_id, tag_id)
        [tag_id | selected_tag_ids]
      end

    socket =
      socket
      |> assign(:tag_search_query, "")
      |> assign(:picker_selected_tag_ids, new_selected_tag_ids)
      |> reload_creator_tags(creator_id)
      |> maybe_refresh_selected_creator_tags(creator_id)
      # Always close picker after toggling a tag (modal stays open via click_away_disabled)
      |> assign(:tag_picker_open_for, nil)
      |> assign(:tag_picker_source, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_new_tag_color", %{"color" => color}, socket) do
    {:noreply, assign(socket, :new_tag_color, color)}
  end

  @impl true
  def handle_event(
        "quick_create_tag",
        %{"name" => name, "creator-id" => creator_id} = params,
        socket
      ) do
    creator_id = String.to_integer(creator_id)
    brand_id = socket.assigns.brand_id
    color = Map.get(params, "color", socket.assigns.new_tag_color)

    attrs = %{
      name: String.trim(name),
      color: color,
      brand_id: brand_id
    }

    case Creators.create_tag(attrs) do
      {:ok, tag} ->
        # Assign the new tag to the creator
        Creators.assign_tag_to_creator(creator_id, tag.id)

        # Refresh available tags
        available_tags = Creators.list_tags_for_brand(brand_id)
        selected_tag_ids = [tag.id | socket.assigns[:picker_selected_tag_ids] || []]

        socket =
          socket
          |> assign(:available_tags, available_tags)
          |> assign(:tag_search_query, "")
          |> assign(:picker_selected_tag_ids, selected_tag_ids)
          |> reload_creator_tags(creator_id)
          |> maybe_refresh_selected_creator_tags(creator_id)
          # Always close picker after creating a tag (modal stays open via click_away_disabled)
          |> assign(:tag_picker_open_for, nil)
          |> assign(:tag_picker_source, nil)

        {:noreply, socket}

      {:error, changeset} ->
        error_msg =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
          |> Enum.map_join(", ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)

        {:noreply, put_flash(socket, :error, "Failed to create tag: #{error_msg}")}
    end
  end

  @impl true
  def handle_event("delete_tag", %{"tag-id" => tag_id}, socket) do
    count = Creators.count_creators_for_tag(tag_id)

    message =
      case count do
        0 -> "Are you sure you want to delete this tag?"
        1 -> "This tag is currently applied to 1 creator. Are you sure you want to delete it?"
        n -> "This tag is currently applied to #{n} creators. Are you sure you want to delete it?"
      end

    {:noreply, push_event(socket, "confirm_delete_tag", %{tag_id: tag_id, message: message})}
  end

  @impl true
  def handle_event("confirm_delete_tag", %{"tag_id" => tag_id}, socket) do
    brand_id = socket.assigns.brand_id

    case Creators.get_tag(tag_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Tag not found")}

      tag ->
        case Creators.delete_tag(tag) do
          {:ok, _} ->
            available_tags = Creators.list_tags_for_brand(brand_id)

            # Remove from filter if it was selected
            new_filter_ids = Enum.reject(socket.assigns.filter_tag_ids, &(&1 == tag_id))

            new_picker_ids =
              Enum.reject(socket.assigns.picker_selected_tag_ids || [], &(&1 == tag_id))

            socket =
              socket
              |> assign(:available_tags, available_tags)
              |> assign(:filter_tag_ids, new_filter_ids)
              |> assign(:picker_selected_tag_ids, new_picker_ids)
              |> put_flash(:info, "Tag deleted")
              |> load_creators()

            {:noreply, socket}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete tag")}
        end
    end
  end

  # Tag filter handlers
  @impl true
  def handle_event("toggle_tag_filter", _params, socket) do
    {:noreply, assign(socket, :show_tag_filter, !socket.assigns.show_tag_filter)}
  end

  @impl true
  def handle_event("close_tag_filter", _params, socket) do
    {:noreply, assign(socket, :show_tag_filter, false)}
  end

  @impl true
  def handle_event("toggle_filter_tag", %{"tag-id" => tag_id}, socket) do
    current = socket.assigns.filter_tag_ids

    new_filter_ids =
      if tag_id in current do
        Enum.reject(current, &(&1 == tag_id))
      else
        [tag_id | current]
      end

    params = build_query_params(socket, filter_tag_ids: new_filter_ids, page: 1)
    {:noreply, push_patch(socket, to: ~p"/creators?#{params}")}
  end

  @impl true
  def handle_event("clear_tag_filter", _params, socket) do
    params = build_query_params(socket, filter_tag_ids: [], page: 1)
    socket = assign(socket, :show_tag_filter, false)
    {:noreply, push_patch(socket, to: ~p"/creators?#{params}")}
  end

  # Time filter handlers
  @impl true
  def handle_event("toggle_time_filter", _params, socket) do
    {:noreply, assign(socket, :show_time_filter, !socket.assigns.show_time_filter)}
  end

  @impl true
  def handle_event("close_time_filter", _params, socket) do
    {:noreply, assign(socket, :show_time_filter, false)}
  end

  @impl true
  def handle_event("apply_time_filter", %{"after" => after_date, "before" => before_date}, socket) do
    after_val = if after_date == "", do: nil, else: after_date
    before_val = if before_date == "", do: nil, else: before_date

    socket = assign(socket, :show_time_filter, false)
    params = build_query_params(socket, added_after: after_val, added_before: before_val, page: 1)
    {:noreply, push_patch(socket, to: ~p"/creators?#{params}")}
  end

  @impl true
  def handle_event("clear_time_filter", _params, socket) do
    socket = assign(socket, :show_time_filter, false)
    params = build_query_params(socket, added_after: nil, added_before: nil, page: 1)
    {:noreply, push_patch(socket, to: ~p"/creators?#{params}")}
  end

  # Batch tag handlers
  @impl true
  def handle_event("show_batch_tag_picker", _params, socket) do
    if MapSet.size(socket.assigns.selected_ids) > 0 do
      socket =
        socket
        |> assign(:show_batch_tag_picker, true)
        |> assign(:batch_selected_tag_ids, [])

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, "Please select at least one creator")}
    end
  end

  @impl true
  def handle_event("close_batch_tag_picker", _params, socket) do
    socket =
      socket
      |> assign(:show_batch_tag_picker, false)
      |> assign(:batch_selected_tag_ids, [])

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_batch_tag", %{"tag-id" => tag_id}, socket) do
    # tag_id is a UUID string, keep as-is
    current_ids = socket.assigns.batch_selected_tag_ids

    new_ids =
      if tag_id in current_ids do
        List.delete(current_ids, tag_id)
      else
        [tag_id | current_ids]
      end

    {:noreply, assign(socket, :batch_selected_tag_ids, new_ids)}
  end

  @impl true
  def handle_event("apply_batch_tags", _params, socket) do
    creator_ids = MapSet.to_list(socket.assigns.selected_ids)
    tag_ids = socket.assigns.batch_selected_tag_ids
    {:ok, count} = Creators.batch_assign_tags(creator_ids, tag_ids)

    socket =
      socket
      |> assign(:show_batch_tag_picker, false)
      |> assign(:batch_selected_tag_ids, [])
      |> assign(:selected_ids, MapSet.new())
      |> assign(:page, 1)
      |> load_creators()
      |> put_flash(:info, "Added #{count} tag assignments to #{length(creator_ids)} creators")

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

  defp reload_creator_tags(socket, creator_id) do
    # Update the creator in the list with refreshed tags
    creators =
      Enum.map(socket.assigns.creators, fn creator ->
        if creator.id == creator_id do
          tags = Creators.list_tags_for_creator(creator_id, socket.assigns.brand_id)
          Map.put(creator, :creator_tags, tags)
        else
          creator
        end
      end)

    assign(socket, :creators, creators)
  end

  # Update tags on selected_creator if modal is open (without refetching entire record)
  defp maybe_refresh_selected_creator_tags(socket, creator_id) do
    selected_creator = socket.assigns.selected_creator

    if socket.assigns.tag_picker_source == :modal && selected_creator &&
         selected_creator.id == creator_id do
      tags = Creators.list_tags_for_creator(creator_id, socket.assigns.brand_id)
      updated_creator = Map.put(selected_creator, :creator_tags, tags)
      assign(socket, :selected_creator, updated_creator)
    else
      socket
    end
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

  # Creator enrichment PubSub handlers
  @impl true
  def handle_info({:enrichment_started}, socket) do
    {:noreply, assign(socket, :enrichment_syncing, true)}
  end

  @impl true
  def handle_info({:enrichment_completed, stats}, socket) do
    socket =
      socket
      |> assign(:enrichment_syncing, false)
      |> assign(:enrichment_last_sync_at, Settings.get_enrichment_last_sync_at())
      |> assign(:page, 1)
      |> load_creators()
      |> put_flash(
        :info,
        "Enriched #{stats.enriched} creators (#{stats.not_found} not found, #{stats.skipped} skipped)"
      )

    {:noreply, socket}
  end

  @impl true
  def handle_info({:enrichment_failed, reason}, socket) do
    socket =
      socket
      |> assign(:enrichment_syncing, false)
      |> put_flash(:error, "Creator enrichment failed: #{inspect(reason)}")

    {:noreply, socket}
  end

  # Outreach PubSub handler - reload data when outreach completes
  @impl true
  def handle_info({:outreach_sent, _creator}, socket) do
    socket =
      socket
      |> assign(:page, 1)
      |> load_creators()
      |> load_outreach_stats()
      |> maybe_show_dev_mailbox_flash()

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

  # Refresh creator data Phase 2 - see handle_event("refresh_creator_data", ...)
  @impl true
  def handle_info({:refresh_creator_data, id}, socket) do
    creator = Creators.get_creator!(id)

    case CreatorEnrichmentWorker.enrich_single(creator) do
      {:ok, updated_creator} ->
        # Reload creator with full modal data
        updated_creator = Creators.get_creator_for_modal!(updated_creator.id)

        socket =
          socket
          |> assign(:selected_creator, updated_creator)
          |> assign(:refreshing, false)
          |> put_flash(:info, "Creator data refreshed")

        {:noreply, socket}

      {:error, :not_found} ->
        socket =
          socket
          |> assign(:refreshing, false)
          |> put_flash(:error, "Creator not found in TikTok marketplace")

        {:noreply, socket}

      {:error, :no_username} ->
        socket =
          socket
          |> assign(:refreshing, false)
          |> put_flash(:error, "Creator has no TikTok username")

        {:noreply, socket}

      {:error, reason} ->
        socket =
          socket
          |> assign(:refreshing, false)
          |> put_flash(:error, "Refresh failed: #{inspect(reason)}")

        {:noreply, socket}
    end
  end

  defp maybe_show_dev_mailbox_flash(socket) do
    if Application.get_env(:pavoi, :dev_routes) do
      put_flash(socket, :info, "Email sent! View it at /dev/mailbox")
    else
      socket
    end
  end

  defp sync_job_active?(worker) do
    # Oban stores worker names without the "Elixir." prefix
    # inspect() returns "Pavoi.Workers.Foo", to_string() returns "Elixir.Pavoi.Workers.Foo"
    worker_name = inspect(worker)
    now = DateTime.utc_now()
    stale_cutoff = DateTime.add(now, -@sync_job_stale_after_seconds, :second)

    from(j in Oban.Job,
      where: j.worker == ^worker_name,
      where:
        j.state == "executing" or
          (j.state == "available" and j.inserted_at >= ^stale_cutoff) or
          (j.state == "scheduled" and j.scheduled_at <= ^now and j.scheduled_at >= ^stale_cutoff)
    )
    |> Pavoi.Repo.exists?()
  end

  defp enqueue_sync_job(socket, worker, args, assign_key, success_message) do
    now = DateTime.utc_now()

    case worker.new(args) |> Oban.insert() do
      {:ok, job} ->
        syncing = job_active?(job, now)
        message = if syncing, do: success_message, else: "Sync already scheduled."

        socket
        |> assign(assign_key, syncing)
        |> put_flash(:info, message)

      {:error, changeset} ->
        socket
        |> assign(assign_key, false)
        |> put_flash(:error, "Failed to enqueue sync: #{inspect(changeset.errors)}")
    end
  end

  defp job_active?(%Oban.Job{state: "executing"}, _now), do: true
  defp job_active?(%Oban.Job{state: "available"}, _now), do: true

  defp job_active?(%Oban.Job{state: "scheduled", scheduled_at: scheduled_at}, now)
       when not is_nil(scheduled_at) do
    DateTime.compare(scheduled_at, now) in [:lt, :eq]
  end

  defp job_active?(_job, _now), do: false

  defp apply_params(socket, params) do
    socket
    |> assign(:search_query, params["q"] || "")
    |> assign(:badge_filter, params["badge"] || "")
    |> assign(:sort_by, params["sort"] || "gmv")
    |> assign(:sort_dir, params["dir"] || "desc")
    |> assign(:page, parse_page(params["page"]))
    |> assign(:outreach_status, parse_outreach_status(params["status"]))
    |> assign(:selected_ids, MapSet.new())
    |> assign(:all_selected_pending, false)
    |> assign(:filter_tag_ids, parse_tag_ids(params["tags"]))
    |> assign(:added_after, params["after"])
    |> assign(:added_before, params["before"])
  end

  defp parse_outreach_status(nil), do: nil
  defp parse_outreach_status(""), do: nil
  defp parse_outreach_status("all"), do: nil
  defp parse_outreach_status(status) when status in ["pending", "sent", "skipped"], do: status
  defp parse_outreach_status(_), do: nil

  defp parse_tag_ids(nil), do: []
  defp parse_tag_ids(""), do: []

  defp parse_tag_ids(tags_string) do
    tags_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
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
      per_page: per_page,
      filter_tag_ids: filter_tag_ids,
      outreach_status: outreach_status,
      brand_id: brand_id,
      added_after: added_after,
      added_before: added_before
    } = socket.assigns

    opts =
      [page: page, per_page: per_page]
      |> maybe_add_opt(:search_query, search_query)
      |> maybe_add_opt(:badge_level, badge_filter)
      |> maybe_add_opt(:sort_by, sort_by)
      |> maybe_add_opt(:sort_dir, sort_dir)
      |> maybe_add_opt(:outreach_status, outreach_status)
      |> maybe_add_opt(:added_after, added_after)
      |> maybe_add_opt(:added_before, added_before)
      |> maybe_add_tag_filter(filter_tag_ids)

    result = Creators.search_creators_unified(opts)

    # Batch load all related data in efficient queries instead of N+1
    creator_ids = Enum.map(result.creators, & &1.id)
    outreach_logs_map = Outreach.get_latest_email_outreach_logs(creator_ids)
    sample_counts_map = Creators.batch_count_samples(creator_ids)
    tags_map = Creators.batch_list_tags_for_creators(creator_ids, brand_id)
    video_counts_map = Creators.batch_count_videos(creator_ids)
    commission_map = Creators.batch_sum_commission(creator_ids)

    # Add sample counts, tags, video counts, commission, and outreach logs to each creator
    creators_with_data =
      Enum.map(result.creators, fn creator ->
        creator
        |> Map.put(:sample_count, Map.get(sample_counts_map, creator.id, 0))
        |> Map.put(:creator_tags, Map.get(tags_map, creator.id, []))
        |> Map.put(:email_outreach_log, Map.get(outreach_logs_map, creator.id))
        |> Map.put(:video_count, Map.get(video_counts_map, creator.id, 0))
        |> Map.put(:total_commission_cents, Map.get(commission_map, creator.id, 0))
      end)

    # If loading more (page > 1), append to existing
    creators =
      if page > 1 do
        socket.assigns.creators ++ creators_with_data
      else
        creators_with_data
      end

    socket
    |> assign(:loading_creators, false)
    |> assign(:creators, creators)
    |> assign(:total, result.total)
    |> assign(:has_more, result.has_more)
  end

  defp maybe_add_tag_filter(opts, []), do: opts
  defp maybe_add_tag_filter(opts, tag_ids), do: Keyword.put(opts, :tag_ids, tag_ids)

  # Always load outreach stats for the status filter dropdown
  defp load_outreach_stats(socket) do
    stats = Outreach.get_outreach_stats()
    sent_today = Outreach.count_sent_today()
    lark_presets = load_lark_presets()

    socket
    |> assign(:outreach_stats, stats)
    |> assign(:sent_today, sent_today)
    |> assign(:lark_presets, lark_presets)
  end

  defp load_lark_presets do
    Enum.map(@lark_presets, fn {id, preset} ->
      url = Settings.get_setting(preset.key) || preset.default_url
      {id, %{label: preset.label, url: url, key: preset.key}}
    end)
    |> Map.new()
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
    tab: :tab,
    outreach_status: :status,
    filter_tag_ids: :tags,
    added_after: :after,
    added_before: :before
  }

  defp build_query_params(socket, overrides) do
    base = %{
      q: socket.assigns.search_query,
      badge: socket.assigns.badge_filter,
      sort: socket.assigns.sort_by,
      dir: socket.assigns.sort_dir,
      page: socket.assigns.page,
      c: get_creator_id(socket.assigns.selected_creator),
      tab: socket.assigns.active_tab,
      status: socket.assigns.outreach_status,
      tags: format_tag_ids(socket.assigns.filter_tag_ids),
      after: socket.assigns.added_after,
      before: socket.assigns.added_before
    }

    overrides
    |> Enum.reduce(base, fn {key, value}, acc ->
      value =
        if key == :filter_tag_ids do
          format_tag_ids(value)
        else
          value
        end

      Map.put(acc, Map.fetch!(@override_key_mapping, key), value)
    end)
    |> reject_default_values()
  end

  defp format_tag_ids([]), do: nil
  defp format_tag_ids(tag_ids), do: Enum.join(tag_ids, ",")

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
  defp default_value?({:sort, nil}), do: true
  defp default_value?({:dir, "desc"}), do: true
  defp default_value?({:tab, "contact"}), do: true
  # Note: nil is now the default for status (show all), so specific statuses are kept in URL
  defp default_value?(_), do: false

  # Computes whether all selected creators have "pending" outreach status
  # Used to show/hide Skip and Send Welcome bulk actions
  defp compute_all_selected_pending(socket) do
    selected_ids = socket.assigns.selected_ids
    creators = socket.assigns.creators

    all_pending =
      if MapSet.size(selected_ids) == 0 do
        false
      else
        selected_creators = Enum.filter(creators, &MapSet.member?(selected_ids, &1.id))
        Enum.all?(selected_creators, &(&1.outreach_status == "pending"))
      end

    assign(socket, :all_selected_pending, all_pending)
  end

  defp maybe_load_selected_creator(socket, params) do
    case params["c"] do
      nil ->
        socket
        |> assign(:selected_creator, nil)
        |> assign(:active_tab, "contact")
        |> assign(:editing_contact, false)
        |> assign(:contact_form, nil)
        |> assign(:modal_samples, nil)
        |> assign(:modal_purchases, nil)
        |> assign(:modal_videos, nil)
        |> assign(:modal_performance, nil)
        |> assign(:modal_fulfillment_stats, nil)

      creator_id ->
        # Load only basic creator info + tags (not samples/videos/performance)
        creator = Creators.get_creator_for_modal!(creator_id)
        tab = params["tab"] || "contact"
        fulfillment_stats = Creators.get_fulfillment_stats(creator_id)

        socket
        |> assign(:selected_creator, creator)
        |> assign(:active_tab, tab)
        # Reset lazy-loaded data
        |> assign(:modal_samples, nil)
        |> assign(:modal_purchases, nil)
        |> assign(:modal_videos, nil)
        |> assign(:modal_performance, nil)
        |> assign(:modal_fulfillment_stats, fulfillment_stats)
        # Load the data for the active tab
        |> load_modal_tab_data(tab, creator.id)
    end
  end

  # Load tab-specific data on demand
  defp load_modal_tab_data(socket, "contact", _creator_id), do: socket

  defp load_modal_tab_data(socket, "samples", creator_id) do
    if socket.assigns.modal_samples do
      socket
    else
      assign(socket, :modal_samples, Creators.get_samples_for_modal(creator_id))
    end
  end

  defp load_modal_tab_data(socket, "purchases", creator_id) do
    if socket.assigns.modal_purchases do
      socket
    else
      assign(socket, :modal_purchases, Creators.get_purchases_for_modal(creator_id))
    end
  end

  defp load_modal_tab_data(socket, "videos", creator_id) do
    if socket.assigns.modal_videos do
      socket
    else
      assign(socket, :modal_videos, Creators.get_videos_for_modal(creator_id))
    end
  end

  defp load_modal_tab_data(socket, "performance", creator_id) do
    if socket.assigns.modal_performance do
      socket
    else
      assign(socket, :modal_performance, Creators.get_performance_for_modal(creator_id))
    end
  end

  defp load_modal_tab_data(socket, _tab, _creator_id), do: socket
end
