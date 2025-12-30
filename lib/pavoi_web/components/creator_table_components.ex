defmodule PavoiWeb.CreatorTableComponents do
  @moduledoc """
  Table components for creator CRM including data grids and sorting.
  """
  use Phoenix.Component

  import PavoiWeb.CoreComponents
  import PavoiWeb.ViewHelpers
  import PavoiWeb.CreatorComponents
  import PavoiWeb.CreatorTagComponents

  alias Pavoi.Creators.Creator
  alias Pavoi.Outreach.OutreachLog
  alias Phoenix.LiveView.JS

  use Phoenix.VerifiedRoutes,
    endpoint: PavoiWeb.Endpoint,
    router: PavoiWeb.Router,
    statics: PavoiWeb.static_paths()

  @doc """
  Renders a data freshness status indicator.
  Shows last sync times for various data sources with color-coded staleness indicators on hover.
  """
  attr :videos_last_import_at, :any, default: nil
  attr :enrichment_last_sync_at, :any, default: nil
  attr :bigquery_last_sync_at, :any, default: nil

  def data_freshness_panel(assigns) do
    assigns =
      assigns
      |> assign(:videos_status, freshness_status(assigns.videos_last_import_at))
      |> assign(:enrichment_status, freshness_status(assigns.enrichment_last_sync_at))
      |> assign(:bigquery_status, freshness_status(assigns.bigquery_last_sync_at))

    ~H"""
    <div class="data-freshness">
      <div class="data-freshness__summary">
        <svg
          xmlns="http://www.w3.org/2000/svg"
          fill="none"
          viewBox="0 0 24 24"
          stroke-width="1.5"
          stroke="currentColor"
          class="data-freshness__icon"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            d="M12 6v6h4.5m4.5 0a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z"
          />
        </svg>
        <%= if has_stale_data?([@videos_status, @enrichment_status, @bigquery_status]) do %>
          <span class="data-freshness__warning">!</span>
        <% end %>
      </div>

      <div class="data-freshness__panel">
        <div class="data-freshness__header">Data Freshness</div>

        <div class="data-freshness__item">
          <span class={"data-freshness__dot data-freshness__dot--#{@bigquery_status.level}"} />
          <div class="data-freshness__label">
            <strong>Shop Orders</strong>
            <span class="data-freshness__source">Auto-synced</span>
          </div>
          <span class="data-freshness__time">{@bigquery_status.text}</span>
        </div>

        <div class="data-freshness__item">
          <span class={"data-freshness__dot data-freshness__dot--#{@enrichment_status.level}"} />
          <div class="data-freshness__label">
            <strong>Creator Profiles</strong>
            <span class="data-freshness__source">Auto-synced</span>
          </div>
          <span class="data-freshness__time">{@enrichment_status.text}</span>
        </div>

        <div class="data-freshness__item">
          <span class={"data-freshness__dot data-freshness__dot--#{@videos_status.level}"} />
          <div class="data-freshness__label">
            <strong>Video Performance</strong>
            <span class="data-freshness__source">Manual CSV</span>
          </div>
          <span class="data-freshness__time">{@videos_status.text}</span>
        </div>

        <div class="data-freshness__legend">
          <span><span class="data-freshness__dot data-freshness__dot--fresh" /> &lt;3 days</span>
          <span><span class="data-freshness__dot data-freshness__dot--aging" /> 3-7 days</span>
          <span><span class="data-freshness__dot data-freshness__dot--stale" /> &gt;7 days</span>
        </div>
      </div>
    </div>
    """
  end

  defp freshness_status(nil) do
    %{level: "stale", text: "Never synced", days: nil}
  end

  defp freshness_status(datetime) do
    days = DateTime.diff(DateTime.utc_now(), datetime, :day)

    cond do
      days < 3 ->
        %{level: "fresh", text: format_relative_time(datetime), days: days}

      days < 7 ->
        %{level: "aging", text: format_relative_time(datetime), days: days}

      true ->
        %{level: "stale", text: format_relative_time(datetime), days: days}
    end
  end

  defp has_stale_data?(statuses) do
    Enum.any?(statuses, fn s -> s.level == "stale" end)
  end

  @doc """
  Renders the status filter dropdown for filtering by outreach status.
  """
  attr :current_status, :string, default: nil
  attr :stats, :map, default: %{pending: 0, sent: 0, skipped: 0}
  attr :open, :boolean, default: false

  def status_filter(assigns) do
    label =
      case assigns.current_status do
        nil -> "All Status"
        "pending" -> "Pending"
        "sent" -> "Sent"
        "skipped" -> "Skipped"
        _ -> "All Status"
      end

    total = assigns.stats.pending + assigns.stats.sent + assigns.stats.skipped
    assigns = assign(assigns, label: label, total: total)

    ~H"""
    <div class="status-filter" phx-click-away={@open && "close_status_filter"}>
      <button
        type="button"
        class={["status-filter__trigger", @current_status && "status-filter__trigger--active"]}
        phx-click="toggle_status_filter"
      >
        <span>{@label}</span>
        <%= if @current_status do %>
          <span class="status-filter__clear-x" phx-click="clear_status_filter" title="Clear filter">
            ×
          </span>
        <% else %>
          <.icon name="hero-chevron-down" class="size-4" />
        <% end %>
      </button>

      <%= if @open do %>
        <div class="status-filter__dropdown">
          <div class="status-filter__list">
            <button
              type="button"
              class={["status-filter__item", !@current_status && "status-filter__item--selected"]}
              phx-click="change_outreach_status"
              phx-value-status=""
            >
              All <span class="status-filter__badge">{@total}</span>
            </button>
            <button
              type="button"
              class={[
                "status-filter__item",
                @current_status == "pending" && "status-filter__item--selected"
              ]}
              phx-click="change_outreach_status"
              phx-value-status="pending"
            >
              Pending <span class="status-filter__badge">{@stats.pending}</span>
            </button>
            <button
              type="button"
              class={[
                "status-filter__item",
                @current_status == "sent" && "status-filter__item--selected"
              ]}
              phx-click="change_outreach_status"
              phx-value-status="sent"
            >
              Sent <span class="status-filter__badge">{@stats.sent}</span>
            </button>
            <button
              type="button"
              class={[
                "status-filter__item",
                @current_status == "skipped" && "status-filter__item--selected"
              ]}
              phx-click="change_outreach_status"
              phx-value-status="skipped"
            >
              Skipped <span class="status-filter__badge">{@stats.skipped}</span>
            </button>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a unified creator table with all columns.
  Adds checkbox column when in outreach mode with pending status.
  """
  attr :creators, :list, required: true
  attr :mode, :string, default: "crm"
  attr :on_row_click, :string, default: nil
  attr :sort_by, :string, default: nil
  attr :sort_dir, :string, default: "asc"
  attr :on_sort, :string, default: nil
  attr :selected_ids, :any, default: nil
  attr :status, :string, default: nil
  attr :total_count, :integer, default: 0

  def creator_table(assigns) do
    # Add 'has-checkbox' class when checkboxes should be shown
    # CRM mode always has checkbox, outreach only in pending status
    has_checkbox =
      assigns.mode == "crm" || (assigns.mode == "outreach" && assigns.status == "pending")

    all_selected =
      has_checkbox && assigns.selected_ids &&
        MapSet.size(assigns.selected_ids) == assigns.total_count &&
        assigns.total_count > 0

    assigns =
      assigns
      |> assign(:has_checkbox, has_checkbox)
      |> assign(:all_selected, all_selected)

    ~H"""
    <div class="creator-table-wrapper">
      <table
        id={"creators-table-#{@mode}"}
        class={["creator-table", "mode-#{@mode}", @has_checkbox && "has-checkbox"]}
        phx-hook="ColumnResize"
        data-table-id={"creators-#{@mode}"}
      >
        <thead>
          <tr>
            <%= if @has_checkbox do %>
              <th class="col-checkbox" data-resizable="false" data-column-id="checkbox">
                <input
                  type="checkbox"
                  checked={@all_selected}
                  phx-click={if @all_selected, do: "deselect_all", else: "select_all"}
                  title={if @all_selected, do: "Deselect All", else: "Select All"}
                />
              </th>
            <% end %>
            <.sort_header
              label="Username"
              field="username"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
            />
            <.sort_header
              label="Name"
              field="name"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
            />
            <.sort_header
              label="Email"
              field="email"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
            />
            <.sort_header
              label="Phone"
              field="phone"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
            />
            <%= if @mode == "crm" do %>
              <th class="col-tags" data-column-id="tags">Tags</th>
            <% end %>
            <%= if @mode == "outreach" do %>
              <.sort_header
                label="SMS Consent"
                field="sms_consent"
                current={@sort_by}
                dir={@sort_dir}
                on_sort={@on_sort}
              />
              <th data-column-id="status">Status</th>
              <.sort_header
                label="Added"
                field="added"
                current={@sort_by}
                dir={@sort_dir}
                on_sort={@on_sort}
              />
              <%= if @status == "sent" do %>
                <.sort_header
                  label="Sent"
                  field="sent"
                  current={@sort_by}
                  dir={@sort_dir}
                  on_sort={@on_sort}
                />
              <% end %>
            <% else %>
              <.sort_header
                label="Followers"
                field="followers"
                current={@sort_by}
                dir={@sort_dir}
                on_sort={@on_sort}
              />
              <.sort_header
                label="GMV"
                field="gmv"
                current={@sort_by}
                dir={@sort_dir}
                on_sort={@on_sort}
              />
              <.sort_header
                label="Samples"
                field="samples"
                current={@sort_by}
                dir={@sort_dir}
                on_sort={@on_sort}
              />
              <.sort_header
                label="Videos"
                field="videos"
                current={@sort_by}
                dir={@sort_dir}
                on_sort={@on_sort}
              />
            <% end %>
          </tr>
        </thead>
        <tbody>
          <%= for creator <- @creators do %>
            <tr
              phx-click={@on_row_click}
              phx-value-id={creator.id}
              class={[
                @on_row_click && "cursor-pointer hover:bg-hover",
                @has_checkbox && @selected_ids && MapSet.member?(@selected_ids, creator.id) &&
                  "row--selected"
              ]}
            >
              <%= if @has_checkbox do %>
                <td class="col-checkbox" phx-click="stop_propagation">
                  <input
                    type="checkbox"
                    checked={@selected_ids && MapSet.member?(@selected_ids, creator.id)}
                    phx-click="toggle_selection"
                    phx-value-id={creator.id}
                  />
                </td>
              <% end %>

              <td class="text-secondary">
                <%= cond do %>
                  <% creator.tiktok_username && creator.tiktok_profile_url -> %>
                    <a
                      href={creator.tiktok_profile_url}
                      target="_blank"
                      rel="noopener"
                      class="link"
                      phx-click="stop_propagation"
                    >
                      @{creator.tiktok_username}
                    </a>
                  <% creator.tiktok_username -> %>
                    @{creator.tiktok_username}
                  <% true -> %>
                    -
                <% end %>
              </td>
              <td>{display_name(creator)}</td>
              <td class="text-secondary">{creator.email || "-"}</td>
              <td class="text-secondary font-mono">{format_phone(creator.phone)}</td>

              <%= if @mode == "crm" do %>
                <td class="col-tags" phx-click="stop_propagation">
                  <.tag_cell creator={creator} />
                </td>
              <% end %>

              <%= if @mode == "outreach" do %>
                <td>
                  <%= if creator.sms_consent do %>
                    <span class="badge badge--soft badge--success">Yes</span>
                  <% else %>
                    <span class="badge badge--soft badge--muted">No</span>
                  <% end %>
                </td>
                <td>
                  <span class={[
                    "badge badge--soft",
                    creator.outreach_status == "pending" && "badge--warning",
                    creator.outreach_status == "sent" && "badge--success",
                    creator.outreach_status == "skipped" && "badge--muted",
                    creator.outreach_status == "unsubscribed" && "badge--muted"
                  ]}>
                    {display_status(creator.outreach_status)}
                  </span>
                </td>
                <td class="text-secondary text-xs">
                  {format_relative_time(creator.inserted_at)}
                </td>
                <%= if @status == "sent" do %>
                  <td class="text-secondary text-xs">
                    <%= if creator.outreach_sent_at do %>
                      {format_relative_time(creator.outreach_sent_at)}
                    <% else %>
                      -
                    <% end %>
                  </td>
                <% end %>
              <% else %>
                <td class="text-right">{format_number(creator.follower_count)}</td>
                <td class="text-right">{format_gmv(creator.total_gmv_cents)}</td>
                <td class="text-right">{creator.sample_count || 0}</td>
                <td class="text-right">{creator.total_videos || 0}</td>
              <% end %>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders a unified creator table with all 13 columns from both CRM and Outreach modes.
  Columns: Checkbox, Username, Name, Email, Phone, Tags, Followers, GMV, Samples, Videos, SMS, Status, Added
  """
  attr :creators, :list, required: true
  attr :on_row_click, :string, default: nil
  attr :sort_by, :string, default: nil
  attr :sort_dir, :string, default: "asc"
  attr :on_sort, :string, default: nil
  attr :selected_ids, :any, default: nil
  attr :total_count, :integer, default: 0
  attr :delta_period, :integer, default: nil

  def unified_creator_table(assigns) do
    all_selected =
      assigns.selected_ids && MapSet.size(assigns.selected_ids) == assigns.total_count &&
        assigns.total_count > 0

    # Whether time filter is active (shows deltas for GMV/Followers)
    time_filter_active = assigns.delta_period != nil

    assigns =
      assigns
      |> assign(:all_selected, all_selected)
      |> assign(:time_filter_active, time_filter_active)

    ~H"""
    <div class="creator-table-wrapper">
      <table
        id="unified-creators-table"
        class="creator-table mode-unified has-checkbox"
        phx-hook="ColumnResize"
        data-table-id="creators-unified"
        data-time-filter={@delta_period}
      >
        <thead>
          <tr>
            <%!-- 1. Checkbox --%>
            <th class="col-checkbox" data-resizable="false" data-column-id="checkbox">
              <input
                type="checkbox"
                checked={@all_selected}
                phx-click={if @all_selected, do: "deselect_all", else: "select_all"}
                title={if @all_selected, do: "Deselect All", else: "Select All"}
              />
            </th>
            <%!-- 2. Status --%>
            <.sort_header
              label="Status"
              field="status"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
              tooltip="Outreach email engagement status"
            />
            <%!-- 3. Avatar + Username --%>
            <.sort_header
              label="Creator"
              field="username"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
              tooltip="TikTok username and display name"
            />
            <%!-- 4. Email --%>
            <.sort_header
              label="Email"
              field="email"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
              tooltip="Contact email address"
            />
            <%!-- 5. Tags --%>
            <th class="col-tags" data-column-id="tags" title="Custom tags for organization">
              Tags
            </th>
            <%!-- 6. Followers --%>
            <.sort_header
              label="Followers"
              field="followers"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
              tooltip="TikTok follower count · Creator Profiles sync"
              time_filtered={@time_filter_active}
            />
            <%!-- 7. Total GMV --%>
            <.sort_header
              label="GMV"
              field="gmv"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
              tooltip="Total gross merchandise value · Creator Profiles sync"
              time_filtered={@time_filter_active}
            />
            <%!-- 8. Avg Views --%>
            <.sort_header
              label="Avg Views"
              field="avg_views"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
              tooltip="Average video views · Creator Profiles sync"
            />
            <%!-- 9. Samples --%>
            <.sort_header
              label="Samples"
              field="samples"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
              tooltip="Sample products sent · Shop Orders sync"
            />
            <%!-- 10. Videos Posted --%>
            <.sort_header
              label="Videos"
              field="videos_posted"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
              tooltip="Affiliate videos posted · Manual CSV (may be stale)"
              manual_import={true}
            />
            <%!-- 11. Commission --%>
            <.sort_header
              label="Commission"
              field="commission"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
              tooltip="Total commission earned · Manual CSV (may be stale)"
              manual_import={true}
            />
            <%!-- 12. Last Sample --%>
            <.sort_header
              label="Last Sample"
              field="last_sample"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
              tooltip="Most recent sample received · Shop Orders sync"
            />
          </tr>
        </thead>
        <tbody>
          <%= for creator <- @creators do %>
            <tr
              phx-click={@on_row_click}
              phx-value-id={creator.id}
              class={[
                @on_row_click && "cursor-pointer hover:bg-hover",
                @selected_ids && MapSet.member?(@selected_ids, creator.id) && "row--selected"
              ]}
            >
              <%!-- 1. Checkbox --%>
              <td data-column-id="checkbox" class="col-checkbox" phx-click="stop_propagation">
                <input
                  type="checkbox"
                  checked={@selected_ids && MapSet.member?(@selected_ids, creator.id)}
                  phx-click="toggle_selection"
                  phx-value-id={creator.id}
                />
              </td>
              <%!-- 2. Status --%>
              <td data-column-id="status" class="text-center">
                <.engagement_status_badge creator={creator} />
              </td>
              <%!-- 3. Avatar + Username + Nickname --%>
              <td data-column-id="username">
                <div class="creator-cell">
                  <.creator_avatar creator={creator} size="sm" />
                  <div class="creator-cell__info">
                    <%= cond do %>
                      <% creator.tiktok_username && creator.tiktok_profile_url -> %>
                        <a
                          href={creator.tiktok_profile_url}
                          target="_blank"
                          rel="noopener"
                          class="link creator-cell__username"
                          phx-click="stop_propagation"
                        >
                          @{creator.tiktok_username}
                        </a>
                      <% creator.tiktok_username -> %>
                        <span class="creator-cell__username">@{creator.tiktok_username}</span>
                      <% true -> %>
                        <span class="creator-cell__username text-secondary">-</span>
                    <% end %>
                    <%= if creator.tiktok_nickname do %>
                      <span class="creator-cell__nickname">{creator.tiktok_nickname}</span>
                    <% end %>
                  </div>
                </div>
              </td>
              <%!-- 4. Email --%>
              <td data-column-id="email" class="text-secondary">{creator.email || "-"}</td>
              <%!-- 5. Tags --%>
              <td data-column-id="tags" class="col-tags" phx-click="stop_propagation">
                <.tag_cell creator={creator} />
              </td>
              <%!-- 6. Followers --%>
              <td data-column-id="followers" class={["text-right", @time_filter_active && "col-time-filtered"]}>
                <%= if @delta_period && creator.snapshot_delta do %>
                  <.metric_with_delta
                    current={creator.follower_count}
                    delta={creator.snapshot_delta.follower_delta}
                    start_date={creator.snapshot_delta.start_date}
                    has_complete_data={creator.snapshot_delta.has_complete_data}
                    format={:number}
                  />
                <% else %>
                  {format_number(creator.follower_count)}
                <% end %>
              </td>
              <%!-- 7. Total GMV --%>
              <td data-column-id="gmv" class={["text-right", @time_filter_active && "col-time-filtered"]}>
                <%= if @delta_period && creator.snapshot_delta do %>
                  <.metric_with_delta
                    current={creator.total_gmv_cents}
                    delta={creator.snapshot_delta.gmv_delta}
                    start_date={creator.snapshot_delta.start_date}
                    has_complete_data={creator.snapshot_delta.has_complete_data}
                    format={:gmv}
                  />
                <% else %>
                  {format_gmv(creator.total_gmv_cents)}
                <% end %>
              </td>
              <%!-- 8. Avg Views --%>
              <td data-column-id="avg_views" class="text-right">{format_number(creator.avg_video_views)}</td>
              <%!-- 9. Samples --%>
              <td data-column-id="samples" class="text-right">{creator.sample_count || 0}</td>
              <%!-- 10. Videos Posted --%>
              <td data-column-id="videos_posted" class="text-right">{creator.video_count || 0}</td>
              <%!-- 11. Commission --%>
              <td data-column-id="commission" class="text-right">{format_gmv(creator.total_commission_cents)}</td>
              <%!-- 12. Last Sample --%>
              <td data-column-id="last_sample" class="text-right text-secondary">
                {format_relative_time(creator.last_sample_at)}
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders a sortable table header with optional tooltip and time-filter highlighting.
  """
  attr :label, :string, required: true
  attr :field, :string, required: true
  attr :current, :string, default: nil
  attr :dir, :string, default: "asc"
  attr :on_sort, :string, default: nil
  attr :tooltip, :string, default: nil
  attr :time_filtered, :boolean, default: false
  attr :manual_import, :boolean, default: false

  def sort_header(assigns) do
    is_active = assigns.current == assigns.field
    # Toggle direction if clicking the same column, otherwise default to desc for numeric
    next_dir = if is_active && assigns.dir == "desc", do: "asc", else: "desc"

    assigns =
      assigns
      |> assign(:is_active, is_active)
      |> assign(:next_dir, next_dir)

    ~H"""
    <th
      class={[
        "sortable-header",
        @is_active && "sortable-header--active",
        @time_filtered && "sortable-header--time-filtered",
        @manual_import && "sortable-header--manual-import"
      ]}
      data-column-id={@field}
    >
      <%= if @on_sort do %>
        <button
          type="button"
          class="sortable-header__btn"
          phx-click={@on_sort}
          phx-value-field={@field}
          phx-value-dir={@next_dir}
        >
          {@label}
          <%= if @manual_import do %>
            <span class="sortable-header__manual-badge" title="Manual CSV import">!</span>
          <% end %>
          <span class={["sortable-header__icon", !@is_active && "sortable-header__icon--inactive"]}>
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2.5"
              class="sort-icon"
            >
              <%= if @dir == "asc" do %>
                <polyline points="18 15 12 9 6 15"></polyline>
              <% else %>
                <polyline points="6 9 12 15 18 9"></polyline>
              <% end %>
            </svg>
          </span>
        </button>
      <% else %>
        {@label}
        <%= if @manual_import do %>
          <span class="sortable-header__manual-badge" title="Manual CSV import">!</span>
        <% end %>
      <% end %>
      <%= if @tooltip do %>
        <span class="sortable-header__tooltip">
          {@tooltip}
          <%= if @time_filtered do %>
            <span class="sortable-header__tooltip-filter">Showing period change</span>
          <% end %>
        </span>
      <% end %>
    </th>
    """
  end

  @doc """
  Renders a samples table for the creator detail view.
  """
  attr :samples, :list, required: true

  def samples_table(assigns) do
    ~H"""
    <%= if Enum.empty?(@samples) do %>
      <div class="empty-state">
        <.icon name="hero-gift" class="empty-state__icon size-8" />
        <p class="empty-state__title">No samples yet</p>
        <p class="empty-state__description">
          Samples will appear here when synced from TikTok Shop
        </p>
      </div>
    <% else %>
      <table class="creator-table">
        <thead>
          <tr>
            <th>Product</th>
            <th>Brand</th>
            <th>Quantity</th>
            <th>Status</th>
            <th>Ordered</th>
          </tr>
        </thead>
        <tbody>
          <%= for sample <- @samples do %>
            <tr>
              <td>
                <div class="sample-product">
                  <%= if sample.product && sample.product.product_images != [] do %>
                    <img
                      src={
                        hd(sample.product.product_images).thumbnail_path ||
                          hd(sample.product.product_images).path
                      }
                      alt=""
                      class="sample-product__thumb"
                    />
                  <% end %>
                  <span>
                    {sample.product_name || (sample.product && sample.product.name) || "Unknown"}
                  </span>
                </div>
              </td>
              <td>{(sample.brand && sample.brand.name) || "-"}</td>
              <td>{sample.quantity}</td>
              <td>
                <span class={["status-badge", "status-badge--#{sample.status || "pending"}"]}>
                  {sample.status || "pending"}
                </span>
              </td>
              <td class="text-secondary">
                {if sample.ordered_at,
                  do: Calendar.strftime(sample.ordered_at, "%b %d, %Y"),
                  else: "-"}
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    <% end %>
    """
  end

  @doc """
  Renders a purchases table for the creator detail view.
  Shows orders placed BY the creator (creator is the buyer).
  """
  attr :purchases, :list, required: true

  def purchases_table(assigns) do
    ~H"""
    <%= if Enum.empty?(@purchases) do %>
      <div class="empty-state">
        <.icon name="hero-shopping-bag" class="empty-state__icon size-8" />
        <p class="empty-state__title">No purchases yet</p>
        <p class="empty-state__description">
          Orders placed by this creator will appear here
        </p>
      </div>
    <% else %>
      <table class="creator-table">
        <thead>
          <tr>
            <th>Order ID</th>
            <th>Status</th>
            <th class="text-right">Amount</th>
            <th>Products</th>
            <th>Date</th>
          </tr>
        </thead>
        <tbody>
          <%= for purchase <- @purchases do %>
            <tr class={purchase.is_sample_order && "purchase--sample"}>
              <td class="font-mono text-sm">{String.slice(purchase.tiktok_order_id, 0, 12)}...</td>
              <td>
                <span class={["status-badge", status_class(purchase.order_status)]}>
                  {purchase.order_status}
                </span>
              </td>
              <td class="text-right">
                <%= if purchase.is_sample_order do %>
                  <span class="text-secondary">Sample</span>
                <% else %>
                  {format_currency(purchase.total_amount_cents, purchase.currency)}
                <% end %>
              </td>
              <td>
                <%= if purchase.line_items && length(purchase.line_items) > 0 do %>
                  <span class="text-secondary">{length(purchase.line_items)} items</span>
                <% else %>
                  <span class="text-secondary">-</span>
                <% end %>
              </td>
              <td class="text-secondary">
                {if purchase.ordered_at,
                  do: Calendar.strftime(purchase.ordered_at, "%b %d, %Y"),
                  else: "-"}
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    <% end %>
    """
  end

  defp status_class(nil), do: "status-badge--pending"
  defp status_class("COMPLETED"), do: "status-badge--completed"
  defp status_class("CANCELLED"), do: "status-badge--cancelled"
  defp status_class("IN_TRANSIT"), do: "status-badge--in_transit"
  defp status_class("DELIVERED"), do: "status-badge--delivered"
  defp status_class(_), do: "status-badge--pending"

  defp format_currency(nil, _), do: "$0.00"

  defp format_currency(cents, _currency) when is_integer(cents) do
    dollars = cents / 100
    "$#{:erlang.float_to_binary(dollars, decimals: 2)}"
  end

  defp format_currency(_, _), do: "$0.00"

  @doc """
  Renders a videos table for the creator detail view.
  """
  attr :videos, :list, required: true
  attr :username, :string, required: true

  def videos_table(assigns) do
    ~H"""
    <%= if Enum.empty?(@videos) do %>
      <div class="empty-state">
        <.icon name="hero-video-camera" class="empty-state__icon size-8" />
        <p class="empty-state__title">No videos found</p>
        <p class="empty-state__description">
          Video data syncs from TikTok Shop affiliate analytics
        </p>
      </div>
    <% else %>
      <table class="creator-table">
        <thead>
          <tr>
            <th>Video</th>
            <th class="text-right">GMV</th>
            <th class="text-right">Items Sold</th>
            <th class="text-right">Impressions</th>
            <th>Posted</th>
          </tr>
        </thead>
        <tbody>
          <%= for video <- @videos do %>
            <tr>
              <td>
                <%= if url = video_tiktok_url(video, @username) do %>
                  <a
                    href={url}
                    target="_blank"
                    rel="noopener"
                    class="link"
                  >
                    {String.slice(video.tiktok_video_id || "Video", 0, 16)}...
                  </a>
                <% else %>
                  {String.slice(video.tiktok_video_id || "Video", 0, 16)}...
                <% end %>
              </td>
              <td class="text-right">{format_gmv(video.gmv_cents)}</td>
              <td class="text-right">{video.items_sold || 0}</td>
              <td class="text-right">{format_number(video.impressions)}</td>
              <td class="text-secondary">
                {if video.posted_at, do: Calendar.strftime(video.posted_at, "%b %d, %Y"), else: "-"}
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    <% end %>
    """
  end

  defp video_tiktok_url(video, username) do
    cond do
      video.video_url -> video.video_url
      username -> "https://www.tiktok.com/@#{username}/video/#{video.tiktok_video_id}"
      true -> nil
    end
  end

  @doc """
  Renders a performance history table.
  """
  attr :snapshots, :list, required: true

  def performance_table(assigns) do
    ~H"""
    <%= if Enum.empty?(@snapshots) do %>
      <div class="empty-state">
        <.icon name="hero-chart-bar" class="empty-state__icon size-8" />
        <p class="empty-state__title">No performance snapshots</p>
        <p class="empty-state__description">
          Historical metrics from Refunnel and other sources appear here
        </p>
      </div>
    <% else %>
      <table class="creator-table">
        <thead>
          <tr>
            <th>Date</th>
            <th>Source</th>
            <th class="text-right">Followers</th>
            <th class="text-right">GMV</th>
            <th class="text-right">EMV</th>
            <th class="text-right">Posts</th>
          </tr>
        </thead>
        <tbody>
          <%= for snapshot <- @snapshots do %>
            <tr>
              <td>{Calendar.strftime(snapshot.snapshot_date, "%b %d, %Y")}</td>
              <td class="text-secondary">{snapshot.source || "-"}</td>
              <td class="text-right">{format_number(snapshot.follower_count)}</td>
              <td class="text-right">{format_gmv(snapshot.gmv_cents)}</td>
              <td class="text-right">{format_gmv(snapshot.emv_cents)}</td>
              <td class="text-right">{snapshot.total_posts || 0}</td>
            </tr>
          <% end %>
        </tbody>
      </table>
    <% end %>
    """
  end

  @doc """
  Renders the creator detail modal with stats bar and tabbed content.

  ## Attributes
  - `creator` - The selected creator (nil to hide modal)
  - `active_tab` - Current active tab ("contact", "samples", "videos", "performance")
  - `editing_contact` - Whether contact form is in edit mode
  - `contact_form` - The form for editing contact info
  - `tag_picker_open` - Whether tag picker is open from this modal (disables click-away)
  - `samples` - Lazy-loaded samples data (nil if not loaded)
  - `videos` - Lazy-loaded videos data (nil if not loaded)
  - `performance` - Lazy-loaded performance snapshots (nil if not loaded)
  """
  attr :creator, :any, default: nil
  attr :active_tab, :string, default: "contact"
  attr :editing_contact, :boolean, default: false
  attr :contact_form, :any, default: nil
  attr :tag_picker_open, :boolean, default: false
  attr :samples, :list, default: nil
  attr :purchases, :list, default: nil
  attr :videos, :list, default: nil
  attr :performance, :list, default: nil
  attr :fulfillment_stats, :map, default: nil
  attr :refreshing, :boolean, default: false

  def creator_detail_modal(assigns) do
    ~H"""
    <%= if @creator do %>
      <.modal
        id="creator-detail-modal"
        show={true}
        on_cancel={JS.push("close_creator_modal")}
        modal_class="modal__box--wide"
        click_away_disabled={@tag_picker_open}
      >
        <div class="modal__header">
          <div class="creator-modal-header">
            <div class="creator-modal-header__top">
              <.creator_avatar creator={@creator} size="lg" />
              <div class="creator-modal-header__info">
                <div class="creator-modal-header__row">
                  <h2 class="modal__title">
                    <%= if @creator.tiktok_username do %>
                      @{@creator.tiktok_username}
                    <% else %>
                      {Creator.full_name(@creator) || "Creator"}
                    <% end %>
                  </h2>
                  <%= if @creator.tiktok_profile_url do %>
                    <a
                      href={@creator.tiktok_profile_url}
                      target="_blank"
                      rel="noopener"
                      class="link text-sm"
                    >
                      View TikTok Profile →
                    </a>
                  <% end %>
                  <.whitelisted_badge is_whitelisted={@creator.is_whitelisted} />
                  <.badge_pill level={@creator.tiktok_badge_level} />
                </div>
                <%= if @creator.tiktok_nickname do %>
                  <div class="creator-modal-header__nickname">{@creator.tiktok_nickname}</div>
                <% end %>
                <%= if @creator.tiktok_bio do %>
                  <div class="creator-modal-header__bio">{@creator.tiktok_bio}</div>
                <% end %>
              </div>
              <div class="creator-modal-header__actions">
                <.button
                  variant="outline"
                  size="sm"
                  phx-click="refresh_creator_data"
                  phx-value-id={@creator.id}
                  disabled={@refreshing}
                >
                  {if @refreshing, do: "Refreshing...", else: "Refresh Data"}
                </.button>
                <span class="creator-modal-header__refresh-time">
                  Last refreshed: {if @creator.last_enriched_at,
                    do: format_relative_time(@creator.last_enriched_at),
                    else: "Never"}
                </span>
              </div>
            </div>
            <div class="creator-modal-tags" data-modal-tag-target={@creator.id}>
              <.tag_pills tags={@creator.creator_tags} max_visible={999} />
              <button
                type="button"
                class="creator-modal-tags__add"
                phx-click="open_modal_tag_picker"
                title="Add tag"
              >
                +
              </button>
            </div>
          </div>
        </div>

        <div class="modal__body">
          <div class="creator-modal-stats">
            <div class="creator-modal-stat">
              <span class="creator-modal-stat__label">Followers</span>
              <span class="creator-modal-stat__value">{format_number(@creator.follower_count)}</span>
            </div>
            <div class="creator-modal-stat">
              <span class="creator-modal-stat__label">Total GMV</span>
              <span class="creator-modal-stat__value">{format_gmv(@creator.total_gmv_cents)}</span>
            </div>
            <div class="creator-modal-stat">
              <span class="creator-modal-stat__label">Video GMV</span>
              <span class="creator-modal-stat__value">{format_gmv(@creator.video_gmv_cents)}</span>
            </div>
            <div class="creator-modal-stat">
              <span class="creator-modal-stat__label">Avg Views</span>
              <span class="creator-modal-stat__value">{format_number(@creator.avg_video_views)}</span>
            </div>
            <%= if @fulfillment_stats do %>
              <div class="creator-modal-stat">
                <span class="creator-modal-stat__label">Fulfillment</span>
                <span class="creator-modal-stat__value">
                  {@fulfillment_stats.fulfilled}/{@fulfillment_stats.total_samples}
                </span>
              </div>
            <% end %>
          </div>

          <div class="creator-modal-tabs">
            <button
              type="button"
              class={["tab", @active_tab == "contact" && "tab--active"]}
              phx-click="change_tab"
              phx-value-tab="contact"
            >
              Contact
            </button>
            <button
              type="button"
              class={["tab", @active_tab == "samples" && "tab--active"]}
              phx-click="change_tab"
              phx-value-tab="samples"
            >
              Samples
            </button>
            <button
              type="button"
              class={["tab", @active_tab == "purchases" && "tab--active"]}
              phx-click="change_tab"
              phx-value-tab="purchases"
            >
              Purchases
            </button>
            <button
              type="button"
              class={["tab", @active_tab == "videos" && "tab--active"]}
              phx-click="change_tab"
              phx-value-tab="videos"
            >
              Videos
            </button>
            <button
              type="button"
              class={["tab", @active_tab == "performance" && "tab--active"]}
              phx-click="change_tab"
              phx-value-tab="performance"
            >
              Performance
            </button>
          </div>

          <div class="creator-modal-content">
            <%= case @active_tab do %>
              <% "contact" -> %>
                <.contact_tab
                  creator={@creator}
                  editing={@editing_contact}
                  form={@contact_form}
                />
              <% "samples" -> %>
                <.samples_table samples={@samples || []} />
              <% "purchases" -> %>
                <.purchases_table purchases={@purchases || []} />
              <% "videos" -> %>
                <.videos_table videos={@videos || []} username={@creator.tiktok_username} />
              <% "performance" -> %>
                <.performance_table snapshots={@performance || []} />
            <% end %>
          </div>
        </div>
      </.modal>
    <% end %>
    """
  end

  @doc """
  Renders the contact tab content with inline editing.
  """
  attr :creator, :any, required: true
  attr :editing, :boolean, default: false
  attr :form, :any, default: nil

  def contact_tab(assigns) do
    ~H"""
    <div class="contact-tab">
      <%= if @editing && @form do %>
        <.form for={@form} phx-submit="save_contact" phx-change="validate_contact" class="stack">
          <div class="contact-form-grid">
            <.input field={@form[:email]} type="email" label="Email" />
            <.input field={@form[:phone]} type="tel" label="Phone" />
          </div>
          <div class="contact-form-grid">
            <.input field={@form[:first_name]} type="text" label="First Name" />
            <.input field={@form[:last_name]} type="text" label="Last Name" />
          </div>
          <.input field={@form[:address_line_1]} type="text" label="Address Line 1" />
          <.input field={@form[:address_line_2]} type="text" label="Address Line 2" />
          <div class="contact-form-grid contact-form-grid--3">
            <.input field={@form[:city]} type="text" label="City" />
            <.input field={@form[:state]} type="text" label="State" />
            <.input field={@form[:zipcode]} type="text" label="ZIP" />
          </div>
          <.input field={@form[:notes]} type="textarea" label="Notes" rows={3} />
          <.input field={@form[:is_whitelisted]} type="checkbox" label="Whitelisted Creator" />
          <div class="contact-tab__footer">
            <.button type="button" variant="ghost" phx-click="cancel_edit">Cancel</.button>
            <.button type="submit" variant="primary">Save</.button>
          </div>
        </.form>
      <% else %>
        <div class="contact-info-grid">
          <div class="contact-info-row">
            <div class="contact-info-item">
              <dt>Email</dt>
              <dd>{@creator.email || "-"}</dd>
            </div>
            <div class="contact-info-item">
              <dt>Phone</dt>
              <dd class="font-mono">{@creator.phone || "-"}</dd>
            </div>
          </div>
          <div class="contact-info-row">
            <div class="contact-info-item">
              <dt>Name</dt>
              <dd>{display_name(@creator)}</dd>
            </div>
            <div class="contact-info-item">
              <dt>Address</dt>
              <dd>
                <%= if @creator.address_line_1 do %>
                  <div>{@creator.address_line_1}</div>
                  <%= if @creator.address_line_2 do %>
                    <div>{@creator.address_line_2}</div>
                  <% end %>
                  <div>
                    {[@creator.city, @creator.state, @creator.zipcode]
                    |> Enum.filter(& &1)
                    |> Enum.join(", ")}
                  </div>
                <% else %>
                  -
                <% end %>
              </dd>
            </div>
          </div>
          <div class="contact-info-row contact-info-row--full">
            <div class="contact-info-item">
              <dt>Notes</dt>
              <dd>
                <%= if @creator.notes && @creator.notes != "" do %>
                  <div class="notes-card__content">{@creator.notes}</div>
                <% else %>
                  <span class="notes-card__empty">No notes</span>
                <% end %>
              </dd>
            </div>
          </div>
        </div>
        <div class="contact-tab__footer">
          <.button variant="primary" phx-click="edit_contact">
            Edit
          </.button>
        </div>
      <% end %>
    </div>
    """
  end
end
