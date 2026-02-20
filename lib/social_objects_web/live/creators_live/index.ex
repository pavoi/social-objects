defmodule SocialObjectsWeb.CreatorsLive.Index do
  @moduledoc """
  LiveView for the creator CRM list view.

  Displays a paginated, searchable, filterable table of creators.
  Modal overlay for creator details with tabbed interface.
  """
  use SocialObjectsWeb, :live_view

  import Ecto.Query

  on_mount {SocialObjectsWeb.NavHooks, :set_current_page}

  alias SocialObjects.Communications
  alias SocialObjects.Communications.TemplateRenderer
  alias SocialObjects.Creators
  alias SocialObjects.Creators.BrandCreator
  alias SocialObjects.Creators.Creator
  alias SocialObjects.Creators.CsvExporter
  alias SocialObjects.Outreach
  alias SocialObjects.Settings
  alias SocialObjects.Workers.BigQueryOrderSyncWorker
  alias SocialObjects.Workers.CreatorEnrichmentWorker
  alias SocialObjects.Workers.CreatorOutreachWorker
  alias SocialObjects.Workers.VideoSyncWorker
  alias SocialObjectsWeb.BrandRoutes

  import SocialObjectsWeb.CreatorTagComponents
  import SocialObjectsWeb.CreatorTableComponents
  import SocialObjectsWeb.FilterComponents
  import SocialObjectsWeb.ParamHelpers
  import SocialObjectsWeb.ViewHelpers
  import SocialObjectsWeb.BrandPermissions

  @tag_colors ~w(amber blue green red purple gray)

  @impl true
  def mount(_params, _session, socket) do
    brand_id = socket.assigns.current_brand.id

    # Subscribe to BigQuery sync, enrichment, video sync, outreach, euka import, and brand GMV events
    _ =
      if connected?(socket) do
        _ = Phoenix.PubSub.subscribe(SocialObjects.PubSub, "bigquery:sync:#{brand_id}")
        _ = Phoenix.PubSub.subscribe(SocialObjects.PubSub, "creator:enrichment:#{brand_id}")
        _ = Phoenix.PubSub.subscribe(SocialObjects.PubSub, "outreach:updates:#{brand_id}")
        _ = Phoenix.PubSub.subscribe(SocialObjects.PubSub, "video:sync:#{brand_id}")
        _ = Phoenix.PubSub.subscribe(SocialObjects.PubSub, "euka:import:#{brand_id}")
        _ = Phoenix.PubSub.subscribe(SocialObjects.PubSub, "brand_gmv:sync:#{brand_id}")
      end

    bigquery_last_sync_at = Settings.get_bigquery_last_sync_at(brand_id)
    bigquery_syncing = sync_job_blocked?(BigQueryOrderSyncWorker, brand_id)
    enrichment_last_sync_at = Settings.get_enrichment_last_sync_at(brand_id)
    enrichment_syncing = sync_job_blocked?(CreatorEnrichmentWorker, brand_id)
    video_syncing = sync_job_blocked?(VideoSyncWorker, brand_id)
    external_import_last_at = Settings.get_external_import_last_at(brand_id)
    brand_gmv_last_sync_at = Settings.get_brand_gmv_last_sync_at(brand_id)
    features = Application.get_env(:social_objects, :features, [])

    available_tags = Creators.list_tags_for_brand(brand_id)

    socket =
      socket
      |> assign(:creators, [])
      |> assign(:search_query, "")
      |> assign(:sort_by, "cumulative_brand_gmv")
      |> assign(:sort_dir, "desc")
      |> assign(:page, 1)
      |> assign(:per_page, 50)
      |> assign(:total, 0)
      |> assign(:has_more, false)
      |> assign(:loading_creators, false)
      # Modal state
      |> assign(:selected_creator, nil)
      |> assign(:selected_brand_creator, nil)
      |> assign(:active_tab, "contact")
      |> assign(:editing_contact, false)
      |> assign(:contact_form, nil)
      |> assign(:engagement_form, nil)
      # Contact edit locking state
      |> assign(:contact_lock_at, nil)
      |> assign(:contact_conflict, false)
      # Lazy-loaded modal tab data
      |> assign(:modal_samples, nil)
      |> assign(:modal_videos, nil)
      |> assign(:modal_performance, nil)
      |> assign(:modal_fulfillment_stats, nil)
      |> assign(:refreshing, false)
      # Unified creators state (merged CRM + Outreach)
      |> assign(:outreach_status, nil)
      |> assign(:segment_filter, nil)
      |> assign(:last_touchpoint_type_filter, nil)
      |> assign(:preferred_contact_channel_filter, nil)
      |> assign(:next_touchpoint_state_filter, nil)
      |> assign(:can_edit_engagement, can_edit?(socket.assigns))
      |> assign(:selected_ids, MapSet.new())
      |> assign(:select_all_matching, false)
      |> assign(:show_status_filter, false)
      |> assign(:sendable_selected_count, 0)
      |> assign(:tiktok_forwarding_count, 0)
      |> assign(:outreach_stats, %{
        total: 0,
        sampled: 0,
        never_contacted: 0,
        contacted: 0,
        opted_out: 0
      })
      |> assign(:segment_stats, %{
        total: 0,
        rising_star: 0,
        vip_elite: 0,
        vip_stable: 0,
        vip_at_risk: 0,
        unclassified: 0
      })
      |> assign(:engagement_filter_stats, %{
        last_touchpoint_type: %{email: 0, sms: 0, manual: 0},
        preferred_contact_channel: %{email: 0, sms: 0, tiktok_dm: 0},
        next_touchpoint_state: %{scheduled: 0, due_this_week: 0, overdue: 0, unscheduled: 0}
      })
      |> assign(:sent_today, 0)
      |> assign(:outreach_email_override, Keyword.get(features, :outreach_email_override))
      |> assign(:outreach_email_enabled, SocialObjects.FeatureFlags.enabled?("outreach_email"))
      |> assign(:show_send_modal, false)
      # Email template selection
      |> assign(:available_templates, [])
      |> assign(:selected_template_id, nil)
      # Sync state
      |> assign(:bigquery_syncing, bigquery_syncing)
      |> assign(:bigquery_last_sync_at, bigquery_last_sync_at)
      |> assign(:enrichment_syncing, enrichment_syncing)
      |> assign(:enrichment_last_sync_at, enrichment_last_sync_at)
      |> assign(:video_syncing, video_syncing)
      # Tag state
      |> assign(:brand_id, brand_id)
      |> assign(:available_tags, available_tags)
      |> assign(:filter_tag_ids, [])
      |> assign(:tag_picker_open_for, nil)
      |> assign(:tag_picker_source, nil)
      |> assign(:tag_search_query, "")
      |> assign(:new_tag_color, "gray")
      |> assign(:show_batch_tag_picker, false)
      |> assign(:picker_selected_tag_ids, [])
      |> assign(:batch_selected_tag_ids, [])
      # Batch select state
      |> assign(:show_batch_select_modal, false)
      |> assign(:batch_select_input, "")
      |> assign(:batch_select_results, nil)
      |> assign(:batch_select_preview_ids, MapSet.new())
      |> assign(:hide_inactive, true)
      # Time filter state (delta period in days: nil, 7, 30, 90)
      |> assign(:delta_period, nil)
      |> assign(:time_preset, "all")
      # Data freshness state
      |> assign(:videos_last_import_at, Settings.get_videos_last_import_at(brand_id))
      |> assign(:external_import_last_at, external_import_last_at)
      |> assign(:brand_gmv_last_sync_at, brand_gmv_last_sync_at)
      # Page tab (creators vs templates)
      |> assign(:page_tab, "creators")
      # Email template management (for Templates tab)
      |> assign(:templates, [])
      |> assign(:template_type_filter, "email")
      |> assign(:preview_template, nil)
      |> assign(:preview_subject, nil)
      |> assign(:preview_html, nil)

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
    {:noreply, push_patch(socket, to: creators_path(socket, params))}
  end

  @impl true
  def handle_event("sort_column", %{"field" => field, "dir" => dir}, socket) do
    params = build_query_params(socket, sort_by: field, sort_dir: dir, page: 1)
    {:noreply, push_patch(socket, to: creators_path(socket, params))}
  end

  @impl true
  def handle_event("navigate_to_creator", %{"id" => id}, socket) do
    params = build_query_params(socket, creator_id: id)
    {:noreply, push_patch(socket, to: creators_path(socket, params))}
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
        |> assign(:selected_brand_creator, nil)
        |> assign(:active_tab, "contact")
        |> assign(:editing_contact, false)
        |> assign(:contact_form, nil)
        |> assign(:engagement_form, nil)
        |> assign(:tag_picker_open_for, nil)
        |> assign(:tag_picker_source, nil)
        |> push_patch(to: creators_path(socket, params))

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
    {:noreply, push_patch(socket, to: creators_path(socket, params))}
  end

  @impl true
  def handle_event("edit_contact", _params, socket) do
    creator = socket.assigns.selected_creator
    brand_creator = socket.assigns.selected_brand_creator || %BrandCreator{}

    form =
      creator
      |> Creator.changeset(%{})
      |> to_form()

    engagement_form =
      brand_creator
      |> BrandCreator.changeset(%{})
      |> to_form(as: :engagement)

    socket =
      socket
      |> assign(:editing_contact, true)
      |> assign(:contact_form, form)
      |> assign(:engagement_form, engagement_form)
      |> assign(:contact_lock_at, creator.updated_at)
      |> assign(:contact_conflict, false)

    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    socket =
      socket
      |> assign(:editing_contact, false)
      |> assign(:contact_form, nil)
      |> assign(:engagement_form, nil)
      |> assign(:contact_lock_at, nil)
      |> assign(:contact_conflict, false)

    {:noreply, socket}
  end

  @impl true
  def handle_event("validate_contact", params, socket) do
    creator_params = Map.get(params, "creator", %{})
    engagement_params = Map.get(params, "engagement", %{})

    changeset =
      socket.assigns.selected_creator
      |> Creator.changeset(creator_params)
      |> Map.put(:action, :validate)

    engagement_changeset =
      (socket.assigns.selected_brand_creator || %BrandCreator{})
      |> BrandCreator.changeset(engagement_params)
      |> Map.put(:action, :validate)

    socket =
      socket
      |> assign(:contact_form, to_form(changeset))
      |> assign(:engagement_form, to_form(engagement_changeset, as: :engagement))

    {:noreply, socket}
  end

  @impl true
  def handle_event("save_contact", params, socket) do
    authorize socket, :admin do
      lock_at = socket.assigns.contact_lock_at
      creator_params = Map.get(params, "creator", %{})
      engagement_params = Map.get(params, "engagement", %{})

      with {:ok, creator} <-
             Creators.update_creator_contact(
               socket.assigns.selected_creator,
               creator_params,
               lock_at
             ),
           {:ok, brand_creator} <-
             Creators.update_brand_creator_engagement(
               socket.assigns.brand_id,
               socket.assigns.selected_creator.id,
               engagement_params
             ) do
        # Reload with minimal associations (not all tab data)
        creator = Creators.get_creator_for_modal!(socket.assigns.brand_id, creator.id)

        socket =
          socket
          |> assign(:selected_creator, creator)
          |> assign(:selected_brand_creator, brand_creator)
          |> assign(:editing_contact, false)
          |> assign(:contact_form, nil)
          |> assign(:engagement_form, nil)
          |> assign(:contact_lock_at, nil)
          |> assign(:contact_conflict, false)
          |> put_flash(:info, "Contact info updated")

        {:noreply, socket}
      else
        {:error, :stale_entry} ->
          # Record was modified since we started editing - show conflict UI
          socket =
            socket
            |> assign(:contact_conflict, true)
            |> assign(:editing_contact, false)
            |> assign(:contact_form, nil)
            |> assign(:engagement_form, nil)

          {:noreply, socket}

        {:error, %Ecto.Changeset{} = changeset} ->
          if changeset.data.__struct__ == BrandCreator do
            {:noreply, assign(socket, :engagement_form, to_form(changeset, as: :engagement))}
          else
            {:noreply, assign(socket, :contact_form, to_form(changeset))}
          end
      end
    end
  end

  @impl true
  def handle_event("refresh_for_conflict", _params, socket) do
    # Reload fresh creator data after a conflict
    creator_id = socket.assigns.selected_creator.id

    creator = Creators.get_creator_for_modal!(socket.assigns.brand_id, creator_id)
    brand_creator = Creators.get_brand_creator(socket.assigns.brand_id, creator_id)

    socket =
      socket
      |> assign(:selected_creator, creator)
      |> assign(:selected_brand_creator, brand_creator)
      |> assign(:contact_conflict, false)
      |> assign(:engagement_form, nil)
      |> assign(:contact_lock_at, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("stop_propagation", _params, socket) do
    {:noreply, socket}
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
    {:noreply, push_patch(socket, to: creators_path(socket, params))}
  end

  @impl true
  def handle_event("change_outreach_status", params, socket) do
    status = Map.get(params, "selection") || Map.get(params, "status") || ""

    # Convert empty string to nil (meaning "all")
    status = if status in ["", "all"], do: nil, else: status
    socket = assign(socket, :show_status_filter, false)
    params = build_query_params(socket, outreach_status: status, page: 1)
    {:noreply, push_patch(socket, to: creators_path(socket, params))}
  end

  @impl true
  def handle_event("change_segment_filter", %{"selection" => selection}, socket) do
    segment = if selection in ["", "all"], do: nil, else: selection
    params = build_query_params(socket, segment_filter: segment, page: 1)
    {:noreply, push_patch(socket, to: creators_path(socket, params))}
  end

  @impl true
  def handle_event("clear_segment_filter", _params, socket) do
    params = build_query_params(socket, segment_filter: nil, page: 1)
    {:noreply, push_patch(socket, to: creators_path(socket, params))}
  end

  def handle_event("change_last_touchpoint_type_filter", %{"selection" => selection}, socket) do
    last_touchpoint_type = if selection in ["", "all"], do: nil, else: selection

    params =
      build_query_params(socket, last_touchpoint_type_filter: last_touchpoint_type, page: 1)

    {:noreply, push_patch(socket, to: creators_path(socket, params))}
  end

  @impl true
  def handle_event("clear_last_touchpoint_type_filter", _params, socket) do
    params = build_query_params(socket, last_touchpoint_type_filter: nil, page: 1)
    {:noreply, push_patch(socket, to: creators_path(socket, params))}
  end

  @impl true
  def handle_event(
        "change_preferred_contact_channel_filter",
        %{"selection" => selection},
        socket
      ) do
    preferred_contact_channel = if selection in ["", "all"], do: nil, else: selection

    params =
      build_query_params(
        socket,
        preferred_contact_channel_filter: preferred_contact_channel,
        page: 1
      )

    {:noreply, push_patch(socket, to: creators_path(socket, params))}
  end

  @impl true
  def handle_event("clear_preferred_contact_channel_filter", _params, socket) do
    params = build_query_params(socket, preferred_contact_channel_filter: nil, page: 1)
    {:noreply, push_patch(socket, to: creators_path(socket, params))}
  end

  @impl true
  def handle_event("change_next_touchpoint_state_filter", %{"selection" => selection}, socket) do
    next_touchpoint_state = if selection in ["", "all"], do: nil, else: selection

    params =
      build_query_params(socket, next_touchpoint_state_filter: next_touchpoint_state, page: 1)

    {:noreply, push_patch(socket, to: creators_path(socket, params))}
  end

  @impl true
  def handle_event("clear_next_touchpoint_state_filter", _params, socket) do
    params = build_query_params(socket, next_touchpoint_state_filter: nil, page: 1)
    {:noreply, push_patch(socket, to: creators_path(socket, params))}
  end

  @impl true
  def handle_event("update_inline_engagement", %{"inline_engagement" => params}, socket) do
    authorize socket, :admin do
      with {:ok, creator_id} <- parse_id(params["creator_id"]),
           {:ok, attrs} <- inline_engagement_attrs(params["field"], params["value"]),
           {:ok, _brand_creator} <-
             Creators.update_brand_creator_engagement(socket.assigns.brand_id, creator_id, attrs) do
        {:noreply, refresh_inline_engagement(socket, creator_id)}
      else
        {:error, :invalid_field} ->
          {:noreply, socket}

        {:error, :invalid_datetime} ->
          {:noreply, put_flash(socket, :error, "Invalid date format")}

        {:error, %Ecto.Changeset{}} ->
          {:noreply, put_flash(socket, :error, "Unable to update engagement field")}

        :error ->
          {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_event("toggle_selection", %{"id" => id_param}, socket) do
    case parse_id(id_param) do
      {:ok, id} ->
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
          |> assign(:select_all_matching, false)
          |> compute_sendable_selected_count()

        {:noreply, socket}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_all", _params, socket) do
    all_ids = Enum.map(socket.assigns.creators, & &1.id) |> MapSet.new()

    socket =
      socket
      |> assign(:selected_ids, all_ids)
      |> assign(:select_all_matching, false)
      |> compute_sendable_selected_count()

    {:noreply, socket}
  end

  @impl true
  def handle_event("deselect_all", _params, socket) do
    socket =
      socket
      |> assign(:selected_ids, MapSet.new())
      |> assign(:select_all_matching, false)
      |> assign(:sendable_selected_count, 0)
      |> assign(:tiktok_forwarding_count, 0)

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_all_matching", _params, socket) do
    # Mark that all matching creators are selected (virtual selection)
    # The actual IDs will be fetched when needed for operations
    socket =
      socket
      |> assign(:select_all_matching, true)
      |> assign(:selected_ids, MapSet.new())
      |> compute_sendable_selected_count()

    {:noreply, socket}
  end

  @impl true
  def handle_event("show_send_modal", _params, socket) do
    if has_selection?(socket) do
      brand_id = socket.assigns.brand_id
      templates = Communications.list_email_templates(brand_id)
      default_template = Communications.get_default_email_template(brand_id)

      socket =
        socket
        |> assign(:available_templates, templates)
        |> assign(:selected_template_id, default_template && default_template.id)
        |> assign(:show_send_modal, true)

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, "Please select at least one creator")}
    end
  end

  @impl true
  def handle_event("close_send_modal", _params, socket) do
    # If modal was opened from single-select (creator detail modal is open),
    # clear selected_ids to avoid showing batch selection UI
    socket =
      if socket.assigns.selected_creator do
        socket
        |> assign(:show_send_modal, false)
        |> assign(:selected_ids, MapSet.new())
      else
        assign(socket, :show_send_modal, false)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_template", %{"id" => template_id_param}, socket) do
    case parse_id(template_id_param) do
      {:ok, template_id} -> {:noreply, assign(socket, :selected_template_id, template_id)}
      :error -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("send_outreach", _params, socket) do
    with :ok <- require_role(socket, :admin),
         {:ok, template_id} <- validate_template_selected(socket),
         {:ok, sendable_ids} <- get_sendable_creator_ids(socket) do
      {:ok, count} =
        CreatorOutreachWorker.enqueue_batch(socket.assigns.brand_id, sendable_ids, template_id)

      {:noreply, handle_outreach_success(socket, count)}
    else
      {:error, :unauthorized} -> unauthorized_response(socket)
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  # =============================================================================
  # TAG MANAGEMENT EVENT HANDLERS
  # =============================================================================

  @impl true
  def handle_event("open_tag_picker", %{"creator-id" => creator_id_param}, socket) do
    case parse_id(creator_id_param) do
      {:ok, creator_id} ->
        selected_tag_ids = Creators.get_tag_ids_for_creator(socket.assigns.brand_id, creator_id)
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

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("open_modal_tag_picker", _params, socket) do
    creator = socket.assigns.selected_creator

    if creator do
      selected_tag_ids = Creators.get_tag_ids_for_creator(socket.assigns.brand_id, creator.id)
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
    authorize socket, :admin do
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
          _ = Creators.assign_tag_to_creator(creator_id, exact_match.id)
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
  end

  @impl true
  def handle_event("toggle_tag", %{"creator-id" => creator_id_param, "tag-id" => tag_id}, socket) do
    authorize socket, :admin do
      case parse_id(creator_id_param) do
        {:ok, creator_id} ->
          selected_tag_ids = socket.assigns[:picker_selected_tag_ids] || []
          _from_modal = socket.assigns.tag_picker_source == :modal

          # Update the tag assignment
          new_selected_tag_ids =
            if tag_id in selected_tag_ids do
              _ = Creators.remove_tag_from_creator(creator_id, tag_id)
              List.delete(selected_tag_ids, tag_id)
            else
              _ = Creators.assign_tag_to_creator(creator_id, tag_id)
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

        :error ->
          {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_event("select_new_tag_color", %{"color" => color}, socket) do
    {:noreply, assign(socket, :new_tag_color, color)}
  end

  @impl true
  def handle_event(
        "quick_create_tag",
        %{"name" => name, "creator-id" => creator_id_param} = params,
        socket
      ) do
    authorize socket, :admin do
      case parse_id(creator_id_param) do
        {:ok, creator_id} ->
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
              error_msg = format_changeset_errors(changeset)
              {:noreply, put_flash(socket, :error, "Failed to create tag: #{error_msg}")}
          end

        :error ->
          {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_event("delete_tag", %{"tag-id" => tag_id}, socket) do
    authorize socket, :admin do
      count = Creators.count_creators_for_tag(tag_id)

      message =
        case count do
          0 ->
            "Are you sure you want to delete this tag?"

          1 ->
            "This tag is currently applied to 1 creator. Are you sure you want to delete it?"

          n ->
            "This tag is currently applied to #{n} creators. Are you sure you want to delete it?"
        end

      {:noreply, push_event(socket, "confirm_delete_tag", %{tag_id: tag_id, message: message})}
    end
  end

  @impl true
  def handle_event("confirm_delete_tag", %{"tag_id" => tag_id}, socket) do
    authorize socket, :admin do
      brand_id = socket.assigns.brand_id

      case Creators.get_tag(brand_id, tag_id) do
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
  end

  # Tag filter handlers
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
    {:noreply, push_patch(socket, to: creators_path(socket, params))}
  end

  @impl true
  def handle_event("clear_tag_filter", _params, socket) do
    params = build_query_params(socket, filter_tag_ids: [], page: 1)
    {:noreply, push_patch(socket, to: creators_path(socket, params))}
  end

  @impl true
  def handle_event("set_time_preset", %{"preset" => preset}, socket) do
    delta_period = preset_to_delta_period(preset)
    params = build_query_params(socket, delta_period: delta_period, page: 1)
    {:noreply, push_patch(socket, to: creators_path(socket, params))}
  end

  @impl true
  def handle_event("toggle_hide_inactive", _params, socket) do
    params = build_query_params(socket, hide_inactive: !socket.assigns.hide_inactive, page: 1)
    {:noreply, push_patch(socket, to: creators_path(socket, params))}
  end

  # Batch tag handlers
  @impl true
  def handle_event("show_batch_tag_picker", _params, socket) do
    if has_selection?(socket) do
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
    authorize socket, :admin do
      creator_ids = get_selected_creator_ids(socket)
      tag_ids = socket.assigns.batch_selected_tag_ids
      {:ok, count} = Creators.batch_assign_tags(creator_ids, tag_ids)

      socket =
        socket
        |> assign(:show_batch_tag_picker, false)
        |> assign(:batch_selected_tag_ids, [])
        |> assign(:selected_ids, MapSet.new())
        |> assign(:select_all_matching, false)
        |> assign(:page, 1)
        |> load_creators()
        |> put_flash(:info, "Added #{count} tag assignments to #{length(creator_ids)} creators")

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("export_csv", _params, socket) do
    if has_selection?(socket) do
      selected_creators = get_selected_creators(socket)

      csv_content = CsvExporter.generate(selected_creators)
      filename = CsvExporter.filename()

      socket =
        socket
        |> push_event("download_csv", %{content: csv_content, filename: filename})
        |> put_flash(:info, "Exported #{length(selected_creators)} creators to CSV")

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, "Please select at least one creator to export")}
    end
  end

  # =============================================================================
  # BATCH SELECT EVENT HANDLERS
  # =============================================================================

  @impl true
  def handle_event("show_batch_select_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_batch_select_modal, true)
      |> assign(:batch_select_input, "")
      |> assign(:batch_select_results, nil)
      |> assign(:batch_select_preview_ids, MapSet.new())

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_batch_select_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_batch_select_modal, false)
      |> assign(:batch_select_input, "")
      |> assign(:batch_select_results, nil)
      |> assign(:batch_select_preview_ids, MapSet.new())

    {:noreply, socket}
  end

  @impl true
  def handle_event("batch_select_input_change", %{"value" => value}, socket) do
    {:noreply, assign(socket, :batch_select_input, value)}
  end

  @impl true
  def handle_event("batch_select_parse", _params, socket) do
    input = socket.assigns.batch_select_input

    {found_creators, not_found_handles} =
      Creators.find_creators_by_handles(socket.assigns.brand_id, input)

    # Pre-select all found creators
    preview_ids = found_creators |> Enum.map(& &1.id) |> MapSet.new()

    socket =
      socket
      |> assign(:batch_select_results, %{found: found_creators, not_found: not_found_handles})
      |> assign(:batch_select_preview_ids, preview_ids)

    {:noreply, socket}
  end

  @impl true
  def handle_event("batch_select_toggle", %{"id" => id_param}, socket) do
    case parse_id(id_param) do
      {:ok, id} ->
        preview_ids = socket.assigns.batch_select_preview_ids

        preview_ids =
          if MapSet.member?(preview_ids, id) do
            MapSet.delete(preview_ids, id)
          else
            MapSet.put(preview_ids, id)
          end

        {:noreply, assign(socket, :batch_select_preview_ids, preview_ids)}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("batch_select_confirm", _params, socket) do
    new_ids = socket.assigns.batch_select_preview_ids

    # Merge with existing selection
    selected_ids = MapSet.union(socket.assigns.selected_ids, new_ids)

    socket =
      socket
      |> assign(:selected_ids, selected_ids)
      |> assign(:select_all_matching, false)
      |> assign(:show_batch_select_modal, false)
      |> assign(:batch_select_input, "")
      |> assign(:batch_select_results, nil)
      |> assign(:batch_select_preview_ids, MapSet.new())
      |> compute_sendable_selected_count()

    {:noreply, socket}
  end

  # =============================================================================
  # PAGE TAB NAVIGATION
  # =============================================================================

  @impl true
  def handle_event("change_page_tab", %{"tab" => tab}, socket) do
    params = build_query_params(socket, page_tab: tab)
    {:noreply, push_patch(socket, to: creators_path(socket, params))}
  end

  @impl true
  def handle_event("go_to_templates", _params, socket) do
    socket =
      socket
      |> assign(:show_send_modal, false)

    params = build_query_params(socket, page_tab: "templates")
    {:noreply, push_patch(socket, to: creators_path(socket, params))}
  end

  # =============================================================================
  # EMAIL TEMPLATE MANAGEMENT
  # =============================================================================

  @impl true
  def handle_event("preview_template", %{"id" => id}, socket) do
    template = Communications.get_email_template!(socket.assigns.brand_id, id)

    {subject, html} =
      if template.type == :page do
        {nil, template_preview_html(template, socket.assigns.current_brand.name)}
      else
        TemplateRenderer.render_preview(template)
      end

    socket =
      socket
      |> assign(:preview_template, template)
      |> assign(:preview_subject, subject)
      |> assign(:preview_html, html)

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_template_preview", _params, socket) do
    socket =
      socket
      |> assign(:preview_template, nil)
      |> assign(:preview_subject, nil)
      |> assign(:preview_html, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_template_type", params, socket) do
    type = params["type"] || params["selection"] || "email"
    params = build_query_params(socket, template_type_filter: type)
    {:noreply, push_patch(socket, to: creators_path(socket, params))}
  end

  @impl true
  def handle_event("set_default_template", %{"id" => id}, socket) do
    authorize socket, :admin do
      template = Communications.get_email_template!(socket.assigns.brand_id, id)
      {:ok, _} = Communications.set_default_template(template)

      templates =
        Communications.list_all_templates_by_type(
          socket.assigns.brand_id,
          socket.assigns.template_type_filter
        )

      socket =
        socket
        |> assign(:templates, templates)
        |> put_flash(:info, "\"#{template.name}\" is now the default template")

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("duplicate_template", %{"id" => id}, socket) do
    authorize socket, :admin do
      case Communications.duplicate_email_template(socket.assigns.brand_id, id) do
        {:ok, duplicated_template} ->
          edit_path =
            BrandRoutes.brand_path(
              socket.assigns.current_brand,
              "/templates/#{duplicated_template.id}/edit",
              socket.assigns.current_host
            )

          socket =
            socket
            |> put_flash(:info, "Template duplicated. Editing copy.")
            |> push_navigate(to: edit_path)

          {:noreply, socket}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to duplicate template")}
      end
    end
  end

  @impl true
  def handle_event("delete_template", %{"id" => id}, socket) do
    authorize socket, :admin do
      template = Communications.get_email_template!(socket.assigns.brand_id, id)
      {:ok, _} = Communications.delete_email_template(template)

      templates =
        Communications.list_all_templates_by_type(
          socket.assigns.brand_id,
          socket.assigns.template_type_filter
        )

      socket =
        socket
        |> assign(:templates, templates)
        |> put_flash(:info, "Template deleted")

      {:noreply, socket}
    end
  end

  # =============================================================================
  # INFINITE SCROLL IMPLEMENTATION
  # =============================================================================
  #
  # Uses InfiniteScroll hook (assets/js/hooks/infinite_scroll.js)
  # which pushes "load_more" events when scrolling near the bottom.
  #
  # Two-phase loading prevents race conditions:
  #   1. handle_event sets loading_creators=true and returns immediately
  #   2. Client receives diff with loading=true → hook skips further events
  #   3. handle_info loads data and sets loading_creators=false
  #   4. Client receives new data → user scrolls → cycle repeats if needed
  #
  # =============================================================================

  @impl true
  def handle_event("load_more", _params, socket) do
    if socket.assigns.loading_creators or not socket.assigns.has_more do
      {:noreply, socket}
    else
      send(self(), :load_more_creators)
      {:noreply, assign(socket, :loading_creators, true)}
    end
  end

  defp format_changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join(", ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
  end

  # Outreach helpers
  defp validate_template_selected(socket) do
    case socket.assigns.selected_template_id do
      nil -> {:error, "Please select an email template"}
      template_id -> {:ok, template_id}
    end
  end

  defp get_sendable_creator_ids(socket) do
    sendable_ids =
      socket
      |> get_selected_creators()
      |> Enum.filter(&sendable?/1)
      |> Enum.map(& &1.id)

    case sendable_ids do
      [] -> {:error, "No eligible creators selected (all may have opted out or lack email)"}
      ids -> {:ok, ids}
    end
  end

  defp handle_outreach_success(socket, count) do
    if socket.assigns.selected_creator do
      # Single-select: reload creator and stay on modal
      updated_creator =
        Creators.get_creator_for_modal!(
          socket.assigns.brand_id,
          socket.assigns.selected_creator.id
        )

      updated_brand_creator =
        Creators.get_brand_creator(socket.assigns.brand_id, socket.assigns.selected_creator.id)

      socket
      |> assign(:show_send_modal, false)
      |> assign(:selected_ids, MapSet.new())
      |> assign(:select_all_matching, false)
      |> assign(:selected_creator, updated_creator)
      |> assign(:selected_brand_creator, updated_brand_creator)
      |> assign(:page, 1)
      |> put_flash(:info, "Queued email for @#{updated_creator.tiktok_username || "creator"}")
      |> load_creators()
      |> load_outreach_stats()
    else
      # Batch select: navigate to sent filter
      socket
      |> assign(:show_send_modal, false)
      |> assign(:selected_ids, MapSet.new())
      |> assign(:select_all_matching, false)
      |> assign(:sendable_selected_count, 0)
      |> assign(:tiktok_forwarding_count, 0)
      |> put_flash(:info, "Queued #{count} emails for sending")
      |> push_patch(to: creators_path(socket, %{status: "contacted"}))
    end
  end

  # Time preset helpers
  defp preset_to_delta_period("7d"), do: 7
  defp preset_to_delta_period("30d"), do: 30
  defp preset_to_delta_period("90d"), do: 90
  defp preset_to_delta_period(_), do: nil

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
      |> assign(
        :bigquery_last_sync_at,
        Settings.get_bigquery_last_sync_at(socket.assigns.brand_id)
      )
      |> assign(:page, 1)
      |> load_creators()
      |> put_flash(
        :info,
        "Synced #{stats.samples_created} samples (#{stats.creators_created} new creators, #{stats.creators_matched} matched)"
      )

    {:noreply, socket}
  end

  @impl true
  def handle_info({:bigquery_sync_failed, _reason}, socket) do
    socket =
      socket
      |> assign(:bigquery_syncing, false)
      |> put_flash(:error, "BigQuery sync failed. Please try again.")

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
      |> assign(
        :enrichment_last_sync_at,
        Settings.get_enrichment_last_sync_at(socket.assigns.brand_id)
      )
      |> assign(:page, 1)
      |> load_creators()
      |> put_flash(
        :info,
        "Enriched #{stats.enriched} creators (#{stats.not_found} not found, #{stats.skipped} skipped)"
      )

    {:noreply, socket}
  end

  @impl true
  def handle_info({:enrichment_failed, _reason}, socket) do
    socket =
      socket
      |> assign(:enrichment_syncing, false)
      |> put_flash(:error, "Creator enrichment failed. Please try again.")

    {:noreply, socket}
  end

  # Video sync PubSub handlers
  @impl true
  def handle_info({:video_sync_started}, socket) do
    {:noreply, assign(socket, :video_syncing, true)}
  end

  @impl true
  def handle_info({:video_sync_completed, stats}, socket) do
    socket =
      socket
      |> assign(:video_syncing, false)
      |> assign(
        :videos_last_import_at,
        Settings.get_videos_last_import_at(socket.assigns.brand_id)
      )
      |> put_flash(
        :info,
        "Synced #{stats.videos_synced} videos (#{stats.creators_created} new creators)"
      )

    {:noreply, socket}
  end

  @impl true
  def handle_info({:video_sync_failed, _reason}, socket) do
    socket =
      socket
      |> assign(:video_syncing, false)
      |> put_flash(:error, "Video sync failed. Please try again.")

    {:noreply, socket}
  end

  # Euka import PubSub handlers
  @impl true
  def handle_info({:euka_import_completed, _brand_id, stats}, socket) do
    socket =
      socket
      |> assign(
        :external_import_last_at,
        Settings.get_external_import_last_at(socket.assigns.brand_id)
      )
      |> put_flash(
        :info,
        "Euka import completed: #{stats.created} created, #{stats.updated} updated"
      )
      |> load_creators()

    {:noreply, socket}
  end

  @impl true
  def handle_info({:euka_import_failed, _brand_id, _reason}, socket) do
    {:noreply, put_flash(socket, :error, "Euka import failed. Check logs for details.")}
  end

  # Brand GMV sync PubSub handlers
  @impl true
  def handle_info({:brand_gmv_sync_started}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:brand_gmv_sync_completed, stats}, socket) do
    socket =
      socket
      |> assign(
        :brand_gmv_last_sync_at,
        Settings.get_brand_gmv_last_sync_at(socket.assigns.brand_id)
      )
      |> assign(:page, 1)
      |> load_creators()
      |> put_flash(
        :info,
        "Brand GMV synced: #{stats.usernames_processed} creators processed, #{stats.brand_creators_updated} updated"
      )

    {:noreply, socket}
  end

  @impl true
  def handle_info({:brand_gmv_sync_failed, _reason}, socket) do
    socket =
      socket
      |> put_flash(:error, "Brand GMV sync failed. Please try again.")

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

  # Infinite scroll data loading (triggered by handle_event "load_more")
  @impl true
  def handle_info(:load_more_creators, socket) do
    socket =
      socket
      |> assign(:page, socket.assigns.page + 1)
      |> load_creators()
      |> maybe_recompute_sendable_count()

    {:noreply, socket}
  end

  # Refresh creator data Phase 2 - see handle_event("refresh_creator_data", ...)
  @impl true
  def handle_info({:refresh_creator_data, id}, socket) do
    creator = Creators.get_creator!(socket.assigns.brand_id, id)

    case CreatorEnrichmentWorker.enrich_single(socket.assigns.brand_id, creator) do
      {:ok, updated_creator} ->
        # Reload creator with full modal data
        updated_creator =
          Creators.get_creator_for_modal!(socket.assigns.brand_id, updated_creator.id)

        updated_brand_creator =
          Creators.get_brand_creator(socket.assigns.brand_id, updated_creator.id)

        socket =
          socket
          |> assign(:selected_creator, updated_creator)
          |> assign(:selected_brand_creator, updated_brand_creator)
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

      {:error, _reason} ->
        socket =
          socket
          |> assign(:refreshing, false)
          |> put_flash(:error, "Refresh failed. Please try again.")

        {:noreply, socket}
    end
  end

  defp maybe_show_dev_mailbox_flash(socket) do
    if Application.get_env(:social_objects, :dev_routes) do
      put_flash(socket, :info, "Email sent! View it at /dev/mailbox")
    else
      socket
    end
  end

  # Check if there's a job that would block new inserts due to uniqueness constraint
  # This includes: available, scheduled, or executing jobs
  defp sync_job_blocked?(worker, brand_id) do
    worker_name = inspect(worker)

    from(j in Oban.Job,
      where: j.worker == ^worker_name,
      where: j.state in ["available", "scheduled", "executing"],
      where: fragment("?->>'brand_id' = ?", j.args, ^to_string(brand_id))
    )
    |> SocialObjects.Repo.exists?()
  end

  defp creators_path(socket, params) when is_map(params) do
    query = URI.encode_query(params)
    path = if query == "", do: "/creators", else: "/creators?#{query}"
    BrandRoutes.brand_path(socket.assigns.current_brand, path, socket.assigns.current_host)
  end

  defp apply_params(socket, params) do
    delta_period = parse_delta_period(params["period"])
    new_page_tab = params["pt"] || "creators"
    old_page_tab = socket.assigns.page_tab
    template_type = params["tt"] || "email"
    engagement_filters = parse_engagement_filters(params)

    # Preserve selection when only switching tabs (not changing filters/search/page)
    {selected_ids, select_all_matching, sendable_count, tiktok_count} =
      if new_page_tab != old_page_tab do
        # Switching tabs - preserve selection
        {socket.assigns.selected_ids, socket.assigns.select_all_matching,
         socket.assigns.sendable_selected_count, socket.assigns.tiktok_forwarding_count}
      else
        # Normal navigation - clear selection
        {MapSet.new(), false, 0, 0}
      end

    socket
    |> assign(:search_query, params["q"] || "")
    |> assign(:sort_by, params["sort"] || "cumulative_brand_gmv")
    |> assign(:sort_dir, params["dir"] || "desc")
    |> assign(:page, parse_page(params["page"]))
    |> assign(:hide_inactive, parse_hide_inactive(params["hi"]))
    |> assign(:outreach_status, parse_outreach_status(params["status"]))
    |> assign(:segment_filter, parse_segment_filter(params["segment"]))
    |> assign(:last_touchpoint_type_filter, engagement_filters.last_touchpoint_type_filter)
    |> assign(
      :preferred_contact_channel_filter,
      engagement_filters.preferred_contact_channel_filter
    )
    |> assign(:next_touchpoint_state_filter, engagement_filters.next_touchpoint_state_filter)
    |> assign(:selected_ids, selected_ids)
    |> assign(:select_all_matching, select_all_matching)
    |> assign(:sendable_selected_count, sendable_count)
    |> assign(:tiktok_forwarding_count, tiktok_count)
    |> assign(:filter_tag_ids, parse_tag_ids(params["tags"]))
    |> assign(:delta_period, delta_period)
    |> assign(:time_preset, derive_time_preset_from_delta(delta_period))
    |> assign(:page_tab, new_page_tab)
    |> assign(:template_type_filter, template_type)
    |> maybe_load_templates(new_page_tab, template_type)
  end

  defp parse_engagement_filters(params) do
    %{
      last_touchpoint_type_filter:
        parse_last_touchpoint_type_filter(params["last_touchpoint_type"]),
      preferred_contact_channel_filter:
        parse_preferred_contact_channel_filter(params["preferred_contact_channel"]),
      next_touchpoint_state_filter:
        parse_next_touchpoint_state_filter(params["next_touchpoint_state"])
    }
  end

  defp inline_engagement_attrs("last_touchpoint_type", value)
       when value in ["", "email", "sms", "manual"] do
    {:ok, %{"last_touchpoint_type" => blank_to_nil(value)}}
  end

  defp inline_engagement_attrs("preferred_contact_channel", value)
       when value in ["", "email", "sms", "tiktok_dm"] do
    {:ok, %{"preferred_contact_channel" => blank_to_nil(value)}}
  end

  defp inline_engagement_attrs("last_touchpoint_at", value) do
    case parse_inline_datetime(value) do
      {:ok, datetime} -> {:ok, %{"last_touchpoint_at" => datetime}}
      {:error, _} -> {:error, :invalid_datetime}
    end
  end

  defp inline_engagement_attrs("next_touchpoint_at", value) do
    case parse_inline_datetime(value) do
      {:ok, datetime} -> {:ok, %{"next_touchpoint_at" => datetime}}
      {:error, _} -> {:error, :invalid_datetime}
    end
  end

  defp inline_engagement_attrs(_, _), do: {:error, :invalid_field}

  defp parse_inline_datetime(""), do: {:ok, nil}
  defp parse_inline_datetime(nil), do: {:ok, nil}

  defp parse_inline_datetime(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}

      {:error, _} ->
        normalized =
          case String.length(value) do
            16 -> value <> ":00"
            _ -> value
          end

        with {:ok, naive} <- NaiveDateTime.from_iso8601(normalized),
             {:ok, datetime} <- DateTime.from_naive(naive, "Etc/UTC") do
          {:ok, DateTime.truncate(datetime, :second)}
        end
    end
  end

  defp parse_inline_datetime(_), do: {:error, :invalid_datetime}

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp refresh_inline_engagement(socket, creator_id) do
    brand_creator = Creators.get_brand_creator(socket.assigns.brand_id, creator_id)

    creators =
      Enum.map(socket.assigns.creators, fn creator ->
        if creator.id == creator_id do
          creator
          |> Map.put(:last_touchpoint_at, brand_creator && brand_creator.last_touchpoint_at)
          |> Map.put(:last_touchpoint_type, brand_creator && brand_creator.last_touchpoint_type)
          |> Map.put(
            :preferred_contact_channel,
            brand_creator && brand_creator.preferred_contact_channel
          )
          |> Map.put(:next_touchpoint_at, brand_creator && brand_creator.next_touchpoint_at)
        else
          creator
        end
      end)

    socket =
      socket
      |> assign(:creators, creators)

    if socket.assigns.selected_creator && socket.assigns.selected_creator.id == creator_id do
      assign(socket, :selected_brand_creator, brand_creator)
    else
      socket
    end
  end

  # Load templates when on templates tab
  defp maybe_load_templates(socket, "templates", template_type) do
    socket
    |> assign(
      :templates,
      Communications.list_all_templates_by_type(socket.assigns.brand_id, template_type)
    )
  end

  defp maybe_load_templates(socket, _, _template_type), do: socket

  defp parse_delta_period(nil), do: nil
  defp parse_delta_period(""), do: nil
  defp parse_delta_period("7"), do: 7
  defp parse_delta_period("30"), do: 30
  defp parse_delta_period("90"), do: 90
  defp parse_delta_period(_), do: nil

  defp parse_hide_inactive(nil), do: true
  defp parse_hide_inactive(""), do: true
  defp parse_hide_inactive(value) when value in ["true", "1", "on"], do: true
  defp parse_hide_inactive(value) when value in ["false", "0", "off"], do: false
  defp parse_hide_inactive(value) when is_boolean(value), do: value
  defp parse_hide_inactive(_), do: true

  defp derive_time_preset_from_delta(nil), do: "all"
  defp derive_time_preset_from_delta(7), do: "7d"
  defp derive_time_preset_from_delta(30), do: "30d"
  defp derive_time_preset_from_delta(90), do: "90d"

  defp parse_outreach_status(nil), do: nil
  defp parse_outreach_status(""), do: nil
  defp parse_outreach_status("all"), do: nil

  defp parse_outreach_status(status)
       when status in ["never_contacted", "contacted", "opted_out", "sampled"],
       do: status

  defp parse_outreach_status(_), do: nil

  defp parse_segment_filter(nil), do: nil
  defp parse_segment_filter(""), do: nil
  defp parse_segment_filter("all"), do: nil

  defp parse_segment_filter(segment)
       when segment in ["rising_star", "vip_elite", "vip_stable", "vip_at_risk"],
       do: segment

  defp parse_segment_filter(_), do: nil

  defp parse_last_touchpoint_type_filter(nil), do: nil
  defp parse_last_touchpoint_type_filter(""), do: nil

  defp parse_last_touchpoint_type_filter(type) when type in ["email", "sms", "manual"],
    do: type

  defp parse_last_touchpoint_type_filter(_), do: nil

  defp parse_preferred_contact_channel_filter(nil), do: nil
  defp parse_preferred_contact_channel_filter(""), do: nil

  defp parse_preferred_contact_channel_filter(channel)
       when channel in ["email", "sms", "tiktok_dm"],
       do: channel

  defp parse_preferred_contact_channel_filter(_), do: nil

  defp parse_next_touchpoint_state_filter(nil), do: nil
  defp parse_next_touchpoint_state_filter(""), do: nil

  defp parse_next_touchpoint_state_filter(state)
       when state in ["scheduled", "due_this_week", "overdue", "unscheduled"],
       do: state

  defp parse_next_touchpoint_state_filter(_), do: nil

  defp contact_status_filter_options(outreach_stats) do
    [
      {"sampled", "Sampled (#{Map.get(outreach_stats, :sampled, 0)})"},
      {"never_contacted", "Never Contacted (#{Map.get(outreach_stats, :never_contacted, 0)})"},
      {"contacted", "Contacted (#{Map.get(outreach_stats, :contacted, 0)})"},
      {"opted_out", "Opted Out (#{Map.get(outreach_stats, :opted_out, 0)})"}
    ]
  end

  defp creator_status_filter_options(segment_stats) do
    [
      {"rising_star", "Rising Star (#{Map.get(segment_stats, :rising_star, 0)})"},
      {"vip_elite", "VIP Elite (#{Map.get(segment_stats, :vip_elite, 0)})"},
      {"vip_stable", "VIP Stable (#{Map.get(segment_stats, :vip_stable, 0)})"},
      {"vip_at_risk", "At Risk (#{Map.get(segment_stats, :vip_at_risk, 0)})"}
    ]
  end

  defp last_touchpoint_filter_options(engagement_filter_stats) do
    last_touchpoint_type_stats = Map.get(engagement_filter_stats, :last_touchpoint_type, %{})

    [
      {"email", "Email (#{Map.get(last_touchpoint_type_stats, :email, 0)})"},
      {"sms", "SMS (#{Map.get(last_touchpoint_type_stats, :sms, 0)})"},
      {"manual", "Manual (#{Map.get(last_touchpoint_type_stats, :manual, 0)})"}
    ]
  end

  defp preferred_contact_channel_filter_options(engagement_filter_stats) do
    preferred_contact_channel_stats =
      Map.get(engagement_filter_stats, :preferred_contact_channel, %{})

    [
      {"email", "Email (#{Map.get(preferred_contact_channel_stats, :email, 0)})"},
      {"sms", "SMS (#{Map.get(preferred_contact_channel_stats, :sms, 0)})"},
      {"tiktok_dm", "TikTok DM (#{Map.get(preferred_contact_channel_stats, :tiktok_dm, 0)})"}
    ]
  end

  defp next_touchpoint_state_filter_options(engagement_filter_stats) do
    next_touchpoint_state_stats = Map.get(engagement_filter_stats, :next_touchpoint_state, %{})

    [
      {"due_this_week",
       "Due This Week (#{Map.get(next_touchpoint_state_stats, :due_this_week, 0)})"},
      {"scheduled", "Scheduled (#{Map.get(next_touchpoint_state_stats, :scheduled, 0)})"},
      {"overdue", "Overdue (#{Map.get(next_touchpoint_state_stats, :overdue, 0)})"},
      {"unscheduled", "Unscheduled (#{Map.get(next_touchpoint_state_stats, :unscheduled, 0)})"}
    ]
  end

  defp segment_descriptions do
    %{
      "rising_star" => "High Priority — Non-VIP in L30 top 75, high recent performers",
      "vip_elite" => "High Priority — VIP and Trending, top performers currently surging",
      "vip_stable" => "Medium Priority — VIP, not trending, L90 rank ≤ 30, reliable performers",
      "vip_at_risk" => "Monitor — VIP with L90 rank > 30, slipping, needs re-engagement"
    }
  end

  defp parse_tag_ids(nil), do: []
  defp parse_tag_ids(""), do: []

  defp parse_tag_ids(tags_string) do
    tags_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_page(nil), do: 1
  defp parse_page(page) when is_binary(page), do: parse_id_or_default(page, 1)
  defp parse_page(page) when is_integer(page), do: page

  defp load_creators(socket) do
    %{
      search_query: search_query,
      sort_by: sort_by,
      sort_dir: sort_dir,
      page: page,
      per_page: per_page,
      filter_tag_ids: filter_tag_ids,
      outreach_status: outreach_status,
      segment_filter: segment_filter,
      last_touchpoint_type_filter: last_touchpoint_type_filter,
      preferred_contact_channel_filter: preferred_contact_channel_filter,
      next_touchpoint_state_filter: next_touchpoint_state_filter,
      brand_id: brand_id,
      delta_period: delta_period,
      hide_inactive: hide_inactive
    } = socket.assigns

    opts =
      [page: page, per_page: per_page]
      |> maybe_add_opt(:search_query, search_query)
      |> maybe_add_opt(:sort_by, sort_by)
      |> maybe_add_opt(:sort_dir, sort_dir)
      |> maybe_add_opt(:outreach_status, outreach_status)
      |> maybe_add_opt(:segment, segment_filter)
      |> maybe_add_opt(:last_touchpoint_type, last_touchpoint_type_filter)
      |> maybe_add_opt(:preferred_contact_channel, preferred_contact_channel_filter)
      |> maybe_add_opt(:next_touchpoint_state, next_touchpoint_state_filter)
      |> maybe_add_opt(:hide_inactive, hide_inactive)
      |> maybe_add_tag_filter(filter_tag_ids)
      |> Keyword.put(:brand_id, brand_id)

    result = Creators.search_creators_unified(opts)

    # Batch load all related data in efficient queries instead of N+1
    creator_ids = Enum.map(result.creators, & &1.id)
    outreach_logs_map = Outreach.get_latest_email_outreach_logs(brand_id, creator_ids)
    sample_counts_map = Creators.batch_count_samples(brand_id, creator_ids)
    last_sample_at_map = Creators.batch_get_last_sample_at(brand_id, creator_ids)
    tags_map = Creators.batch_list_tags_for_creators(creator_ids, brand_id)
    commission_map = Creators.batch_sum_commission(brand_id, creator_ids)
    brand_creator_map = Creators.batch_load_brand_creator_fields(brand_id, creator_ids)

    # Load snapshot deltas if a time period is selected
    snapshot_deltas_map =
      case delta_period do
        nil -> %{}
        days -> Creators.batch_load_snapshot_deltas(brand_id, creator_ids, days)
      end

    # Default snapshot delta when period is selected but no data exists
    default_snapshot_delta =
      if delta_period do
        %{
          gmv_delta: nil,
          follower_delta: nil,
          start_date: nil,
          end_date: nil,
          has_complete_data: false
        }
      else
        nil
      end

    # Add sample counts, tags, video counts, commission, outreach logs, snapshot deltas, and brand GMV
    creators_with_data =
      Enum.map(result.creators, fn creator ->
        snapshot_delta = Map.get(snapshot_deltas_map, creator.id, default_snapshot_delta)
        brand_creator = Map.get(brand_creator_map, creator.id, %{})

        creator
        |> Map.put(:sample_count, Map.get(sample_counts_map, creator.id, 0))
        |> Map.put(:last_sample_at, Map.get(last_sample_at_map, creator.id))
        |> Map.put(:creator_tags, Map.get(tags_map, creator.id, []))
        |> Map.put(:email_outreach_log, Map.get(outreach_logs_map, creator.id))
        |> Map.put(:video_count, Map.get(brand_creator, :video_count, 0))
        |> Map.put(:total_commission_cents, Map.get(commission_map, creator.id, 0))
        |> Map.put(:snapshot_delta, snapshot_delta)
        |> Map.put(:brand_gmv_cents, Map.get(brand_creator, :brand_gmv_cents, 0))
        |> Map.put(
          :cumulative_brand_gmv_cents,
          Map.get(brand_creator, :cumulative_brand_gmv_cents, 0)
        )
        |> Map.put(
          :brand_gmv_tracking_started_at,
          Map.get(brand_creator, :brand_gmv_tracking_started_at)
        )
        |> Map.put(:last_touchpoint_at, Map.get(brand_creator, :last_touchpoint_at))
        |> Map.put(:last_touchpoint_type, Map.get(brand_creator, :last_touchpoint_type))
        |> Map.put(:preferred_contact_channel, Map.get(brand_creator, :preferred_contact_channel))
        |> Map.put(:next_touchpoint_at, Map.get(brand_creator, :next_touchpoint_at))
        |> Map.put(:is_vip, Map.get(brand_creator, :is_vip, false))
        |> Map.put(:is_trending, Map.get(brand_creator, :is_trending, false))
        |> Map.put(:l30d_rank, Map.get(brand_creator, :l30d_rank))
        |> Map.put(:l90d_rank, Map.get(brand_creator, :l90d_rank))
        |> Map.put(:l30d_gmv_cents, Map.get(brand_creator, :l30d_gmv_cents))
        |> Map.put(:stability_score, Map.get(brand_creator, :stability_score))
        |> Map.put(:engagement_priority, Map.get(brand_creator, :engagement_priority))
        |> Map.put(:vip_locked, Map.get(brand_creator, :vip_locked, false))
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
    stats = Outreach.get_outreach_stats(socket.assigns.brand_id)
    sampled_count = Creators.count_sampled_creators(socket.assigns.brand_id)
    segment_stats = Creators.get_creator_segment_stats(socket.assigns.brand_id)
    engagement_filter_stats = Creators.get_engagement_filter_stats(socket.assigns.brand_id)
    sent_today = Outreach.count_sent_today(socket.assigns.brand_id)

    # Merge sampled count into stats
    stats = Map.put(stats, :sampled, sampled_count)

    socket
    |> assign(:outreach_stats, stats)
    |> assign(:segment_stats, segment_stats)
    |> assign(:engagement_filter_stats, engagement_filter_stats)
    |> assign(:sent_today, sent_today)
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, _key, ""), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  @override_key_mapping %{
    search_query: :q,
    sort_by: :sort,
    sort_dir: :dir,
    page: :page,
    creator_id: :c,
    tab: :tab,
    outreach_status: :status,
    segment_filter: :segment,
    last_touchpoint_type_filter: :last_touchpoint_type,
    preferred_contact_channel_filter: :preferred_contact_channel,
    next_touchpoint_state_filter: :next_touchpoint_state,
    filter_tag_ids: :tags,
    hide_inactive: :hi,
    delta_period: :period,
    page_tab: :pt,
    template_type_filter: :tt
  }

  defp build_query_params(socket, overrides) do
    base = %{
      q: socket.assigns.search_query,
      sort: socket.assigns.sort_by,
      dir: socket.assigns.sort_dir,
      page: socket.assigns.page,
      c: get_creator_id(socket.assigns.selected_creator),
      tab: socket.assigns.active_tab,
      status: socket.assigns.outreach_status,
      segment: socket.assigns.segment_filter,
      last_touchpoint_type: socket.assigns.last_touchpoint_type_filter,
      preferred_contact_channel: socket.assigns.preferred_contact_channel_filter,
      next_touchpoint_state: socket.assigns.next_touchpoint_state_filter,
      tags: format_tag_ids(socket.assigns.filter_tag_ids),
      hi: socket.assigns.hide_inactive,
      period: socket.assigns.delta_period,
      pt: socket.assigns.page_tab,
      tt: socket.assigns.template_type_filter
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
  defp default_value?({:sort, "cumulative_brand_gmv"}), do: true
  defp default_value?({:sort, nil}), do: true
  defp default_value?({:dir, "desc"}), do: true
  defp default_value?({:tab, "contact"}), do: true
  defp default_value?({:pt, "creators"}), do: true
  defp default_value?({:tt, "email"}), do: true
  defp default_value?({:hi, true}), do: true
  # Note: nil is now the default for status (show all), so specific statuses are kept in URL
  defp default_value?(_), do: false

  # Computes how many selected creators can be sent emails
  # A creator is sendable if they have an email and haven't opted out
  # Also counts how many are TikTok forwarding addresses
  defp compute_sendable_selected_count(socket) do
    selected_ids = socket.assigns.selected_ids
    select_all_matching = socket.assigns.select_all_matching
    creators = socket.assigns.creators

    selected_creators =
      cond do
        select_all_matching ->
          # When "select all matching" is active, use all loaded creators
          # Note: This is approximate since not all creators may be loaded
          creators

        MapSet.size(selected_ids) == 0 ->
          []

        true ->
          Enum.filter(creators, &MapSet.member?(selected_ids, &1.id))
      end

    sendable_count = Enum.count(selected_creators, &sendable?/1)
    tiktok_count = Enum.count(selected_creators, &tiktok_forwarding_email?/1)

    socket
    |> assign(:sendable_selected_count, sendable_count)
    |> assign(:tiktok_forwarding_count, tiktok_count)
  end

  # Recompute sendable count if there's an active selection
  defp maybe_recompute_sendable_count(socket) do
    if has_selection?(socket) do
      compute_sendable_selected_count(socket)
    else
      socket
    end
  end

  defp sendable?(creator) do
    creator.email != nil and creator.email != "" and not creator.email_opted_out
  end

  defp tiktok_forwarding_email?(creator) do
    sendable?(creator) and String.ends_with?(creator.email || "", "@scs.tiktokw.us")
  end

  # Returns true if there's an active selection (either explicit IDs or "select all matching")
  defp has_selection?(socket) do
    socket.assigns.select_all_matching or MapSet.size(socket.assigns.selected_ids) > 0
  end

  # Returns list of selected creator structs
  # When select_all_matching is true, returns all loaded creators (which match the filters)
  defp get_selected_creators(socket) do
    if socket.assigns.select_all_matching do
      socket.assigns.creators
    else
      selected_ids = socket.assigns.selected_ids
      Enum.filter(socket.assigns.creators, &MapSet.member?(selected_ids, &1.id))
    end
  end

  # Returns list of selected creator IDs
  # When select_all_matching is true, returns IDs of all loaded creators
  defp get_selected_creator_ids(socket) do
    if socket.assigns.select_all_matching do
      Enum.map(socket.assigns.creators, & &1.id)
    else
      MapSet.to_list(socket.assigns.selected_ids)
    end
  end

  defp maybe_load_selected_creator(socket, params) do
    case params["c"] do
      nil ->
        socket
        |> assign(:selected_creator, nil)
        |> assign(:selected_brand_creator, nil)
        |> assign(:active_tab, "contact")
        |> assign(:editing_contact, false)
        |> assign(:contact_form, nil)
        |> assign(:engagement_form, nil)
        |> assign(:modal_samples, nil)
        |> assign(:modal_purchases, nil)
        |> assign(:modal_videos, nil)
        |> assign(:modal_performance, nil)
        |> assign(:modal_fulfillment_stats, nil)

      creator_id ->
        # Load only basic creator info + tags (not samples/videos/performance)
        creator = Creators.get_creator_for_modal!(socket.assigns.brand_id, creator_id)
        brand_creator = Creators.get_brand_creator(socket.assigns.brand_id, creator.id)
        tab = params["tab"] || "contact"
        fulfillment_stats = Creators.get_fulfillment_stats(socket.assigns.brand_id, creator_id)

        socket
        |> assign(:selected_creator, creator)
        |> assign(:selected_brand_creator, brand_creator)
        |> assign(:active_tab, tab)
        # Reset lazy-loaded data
        |> assign(:modal_samples, nil)
        |> assign(:modal_purchases, nil)
        |> assign(:modal_videos, nil)
        |> assign(:modal_performance, nil)
        |> assign(:modal_fulfillment_stats, fulfillment_stats)
        |> assign(:engagement_form, nil)
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
      assign(
        socket,
        :modal_samples,
        Creators.get_samples_for_modal(socket.assigns.brand_id, creator_id)
      )
    end
  end

  defp load_modal_tab_data(socket, "purchases", creator_id) do
    if socket.assigns.modal_purchases do
      socket
    else
      assign(
        socket,
        :modal_purchases,
        Creators.get_purchases_for_modal(socket.assigns.brand_id, creator_id)
      )
    end
  end

  defp load_modal_tab_data(socket, "videos", creator_id) do
    if socket.assigns.modal_videos do
      socket
    else
      assign(
        socket,
        :modal_videos,
        Creators.get_videos_for_modal(socket.assigns.brand_id, creator_id)
      )
    end
  end

  defp load_modal_tab_data(socket, "performance", creator_id) do
    if socket.assigns.modal_performance do
      socket
    else
      assign(
        socket,
        :modal_performance,
        Creators.get_performance_for_modal(socket.assigns.brand_id, creator_id)
      )
    end
  end

  defp load_modal_tab_data(socket, _tab, _creator_id), do: socket
end
