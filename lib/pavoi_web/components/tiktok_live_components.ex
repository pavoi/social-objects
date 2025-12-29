defmodule PavoiWeb.TiktokLiveComponents do
  @moduledoc """
  Reusable components for TikTok Live stream browsing.
  """
  use Phoenix.Component

  import PavoiWeb.CoreComponents
  import PavoiWeb.CreatorComponents, only: [sort_header: 1]
  import PavoiWeb.ViewHelpers

  alias Pavoi.TiktokLive.Stream
  alias Phoenix.LiveView.JS

  use Phoenix.VerifiedRoutes,
    endpoint: PavoiWeb.Endpoint,
    router: PavoiWeb.Router,
    statics: PavoiWeb.static_paths()

  @doc """
  Renders a status badge for stream status.

  ## Examples

      <.stream_status_badge status={:capturing} />
      <.stream_status_badge status={:ended} />
  """
  attr :status, :atom, required: true

  def stream_status_badge(assigns) do
    {label, class} =
      case assigns.status do
        :capturing -> {"LIVE", "status-badge--live"}
        :ended -> {"Ended", "status-badge--ended"}
        :failed -> {"Failed", "status-badge--failed"}
        _ -> {"Unknown", "status-badge--unknown"}
      end

    assigns = assign(assigns, label: label, class: class)

    ~H"""
    <span class={["status-badge", @class]}>
      <%= if @status == :capturing do %>
        <span class="status-badge__pulse"></span>
      <% end %>
      {@label}
    </span>
    """
  end

  @doc """
  Renders a stream thumbnail image or placeholder.

  ## Examples

      <.stream_thumbnail url={Stream.cover_image_url(stream)} />
  """
  attr :url, :string, default: nil

  def stream_thumbnail(assigns) do
    ~H"""
    <div class="stream-thumbnail">
      <%= if @url do %>
        <img src={@url} alt="Stream thumbnail" class="stream-thumbnail__image" loading="lazy" />
      <% else %>
        <div class="stream-thumbnail__placeholder">
          <.icon name="hero-video-camera" class="stream-thumbnail__icon" />
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders the streams table.
  """
  attr :streams, :list, required: true
  attr :on_row_click, :string, default: nil
  attr :sort_by, :string, default: "started"
  attr :sort_dir, :string, default: "desc"
  attr :on_sort, :string, default: nil

  def streams_table(assigns) do
    ~H"""
    <div class="streams-table-wrapper">
      <table id="streams-table" class="streams-table" phx-hook="ColumnResize" data-table-id="streams">
        <thead>
          <tr>
            <th data-column-id="thumbnail" class="streams-table__th-thumbnail"></th>
            <th data-column-id="title">Title</th>
            <th data-column-id="status">Status</th>
            <.sort_header
              label="Started"
              field="started"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
            />
            <.sort_header
              label="Duration"
              field="duration"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
              class="text-right"
            />
            <.sort_header
              label="Viewers"
              field="viewers"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
              class="text-right"
            />
            <.sort_header
              label="GMV"
              field="gmv"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
              class="text-right"
            />
            <.sort_header
              label="Comments"
              field="comments"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
              class="text-right"
            />
          </tr>
        </thead>
        <tbody>
          <%= for stream <- @streams do %>
            <tr
              phx-click={@on_row_click}
              phx-value-id={stream.id}
              class={[@on_row_click && "cursor-pointer hover:bg-hover"]}
            >
              <td class="streams-table__td-thumbnail">
                <.stream_thumbnail url={Stream.cover_image_url(stream)} />
              </td>
              <td>
                <div class="streams-table__title">
                  <span class="streams-table__title-text">{format_stream_title(stream)}</span>
                  <span class="streams-table__username">@{stream.unique_id}</span>
                </div>
              </td>
              <td>
                <.stream_status_badge status={stream.status} />
              </td>
              <td class="text-secondary">
                {format_stream_time(stream.started_at)}
              </td>
              <td class="text-right text-secondary">
                {format_duration(stream.started_at, stream.ended_at)}
              </td>
              <td class="text-right">
                <%= if stream.status == :capturing do %>
                  <span class="text-live">{format_number(stream.viewer_count_current)}</span>
                <% else %>
                  {format_number(stream.viewer_count_peak)}
                <% end %>
              </td>
              <td class="text-right">
                <%= if stream.gmv_cents do %>
                  <span class="text-green-500">{format_gmv(stream.gmv_cents)}</span>
                <% else %>
                  <span class="text-secondary">—</span>
                <% end %>
              </td>
              <td class="text-right">{format_number(stream.total_comments)}</td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders the stream detail modal.
  """
  attr :stream, :any, default: nil
  attr :summary, :map, default: nil
  attr :active_tab, :string, default: "comments"
  attr :comments, :list, default: []
  attr :has_comments, :boolean, default: false
  attr :comment_search_query, :string, default: ""
  attr :stream_stats, :list, default: []
  attr :stream_gmv, :map, default: nil
  attr :linked_sessions, :list, default: []
  attr :all_sessions, :list, default: []
  attr :session_search_query, :string, default: ""
  attr :product_interest, :list, default: []
  attr :dev_mode, :boolean, default: false
  attr :sending_stream_report, :boolean, default: false
  attr :slack_dev_user_id_present, :boolean, default: false
  attr :stream_report_last_sent_at, :any, default: nil
  attr :stream_report_last_error, :string, default: nil

  def stream_detail_modal(assigns) do
    ~H"""
    <%= if @stream do %>
      <.modal
        id="stream-detail-modal"
        show={true}
        on_cancel={JS.push("close_stream_modal")}
        modal_class="modal__box--wide"
      >
        <div class="modal__header">
          <div class="stream-modal-header">
            <div class="stream-modal-header__top">
              <div class="stream-modal-header__thumbnail">
                <.stream_thumbnail url={Stream.cover_image_url(@stream)} />
              </div>
              <div class="stream-modal-header__info">
                <div class="stream-modal-header__title">
                  <h2 class="modal__title">{format_stream_title(@stream)}</h2>
                  <span class="text-secondary">@{@stream.unique_id}</span>
                </div>
                <div class="stream-modal-header__status">
                  <div class="stream-modal-header__status-left">
                    <.stream_status_badge status={@stream.status} />
                    <span class="text-secondary text-sm">
                      Started {format_relative_time(@stream.started_at)}
                    </span>
                  </div>
                  <div class="stream-modal-header__actions">
                    <%= if @dev_mode do %>
                      <div class="stream-modal-header__action-group">
                        <.button
                          id={"send-slack-report-#{@stream.id}"}
                          variant="ghost"
                          size="sm"
                          phx-click="send_stream_report"
                          phx-value-id={@stream.id}
                          class={@sending_stream_report && "button--disabled"}
                          disabled={@sending_stream_report || !@slack_dev_user_id_present}
                        >
                          <%= if @sending_stream_report do %>
                            Sending Slack Report...
                          <% else %>
                            <%= if @slack_dev_user_id_present do %>
                              Send Slack Report
                            <% else %>
                              Set SLACK_DEV_USER_ID
                            <% end %>
                          <% end %>
                        </.button>
                        <span class={[
                          "stream-modal-header__action-meta",
                          @stream_report_last_error && "stream-modal-header__action-meta--error"
                        ]}>
                          <%= cond do %>
                            <% @stream_report_last_error -> %>
                              <%= if String.starts_with?(@stream_report_last_error, "Retrying") do %>
                                {@stream_report_last_error}
                              <% else %>
                                Failed: {@stream_report_last_error}
                              <% end %>
                            <% @sending_stream_report -> %>
                              Sending...
                            <% !@slack_dev_user_id_present -> %>
                              Dev user id required
                            <% true -> %>
                              Last sent: {format_relative_time(@stream_report_last_sent_at)}
                          <% end %>
                        </span>
                      </div>
                    <% end %>
                    <button
                      type="button"
                      class="button button--sm button--ghost-error"
                      phx-click="delete_stream"
                      phx-value-id={@stream.id}
                      data-confirm="Are you sure you want to delete this stream and all its data? This cannot be undone."
                    >
                      Delete
                    </button>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div class="modal__body">
          <div class="stream-modal-stats">
            <div class="stream-modal-stat">
              <span class="stream-modal-stat__label">Peak Viewers</span>
              <span class="stream-modal-stat__value">{format_number(@stream.viewer_count_peak)}</span>
            </div>
            <div class="stream-modal-stat">
              <span class="stream-modal-stat__label">Likes</span>
              <span class="stream-modal-stat__value">{format_number(@stream.total_likes)}</span>
            </div>
            <div class="stream-modal-stat">
              <span class="stream-modal-stat__label">Gifts</span>
              <span class="stream-modal-stat__value">
                ${format_number(@stream.total_gifts_value)}
              </span>
            </div>
            <div class="stream-modal-stat">
              <span class="stream-modal-stat__label">Comments</span>
              <span class="stream-modal-stat__value">{format_number(@stream.total_comments)}</span>
            </div>
            <%= if @summary do %>
              <div class="stream-modal-stat">
                <span class="stream-modal-stat__label">Duration</span>
                <span class="stream-modal-stat__value">
                  {format_duration_seconds(@summary.duration_seconds)}
                </span>
              </div>
            <% end %>
            <%= if @stream.gmv_cents && @stream.gmv_cents > 0 do %>
              <div class="stream-modal-stat stream-modal-stat--highlight">
                <span class="stream-modal-stat__label">
                  GMV
                  <span
                    class="stream-modal-stat__info"
                    title="Gross Merchandise Value: Total order revenue during stream hours. This is correlation, not direct attribution—orders may or may not be stream-driven."
                  >
                    <.icon name="hero-information-circle" class="size-3.5" />
                  </span>
                </span>
                <span class="stream-modal-stat__value">
                  {format_gmv(@stream.gmv_cents)}
                </span>
                <span class="stream-modal-stat__subvalue">
                  {@stream.gmv_order_count || 0} orders
                </span>
              </div>
            <% end %>
          </div>

          <div class="stream-modal-tabs">
            <button
              type="button"
              class={["tab", @active_tab == "comments" && "tab--active"]}
              phx-click="change_tab"
              phx-value-tab="comments"
            >
              Comments
            </button>
            <button
              type="button"
              class={["tab", @active_tab == "sessions" && "tab--active"]}
              phx-click="change_tab"
              phx-value-tab="sessions"
            >
              Sessions
              <%= if length(@linked_sessions) > 0 do %>
                <span class="tab__badge">{length(@linked_sessions)}</span>
              <% end %>
            </button>
            <button
              type="button"
              class={["tab", @active_tab == "stats" && "tab--active"]}
              phx-click="change_tab"
              phx-value-tab="stats"
            >
              Stats
            </button>
          </div>

          <div class="stream-modal-content">
            <%= case @active_tab do %>
              <% "comments" -> %>
                <.comments_tab
                  comments={@comments}
                  has_comments={@has_comments}
                  search_query={@comment_search_query}
                />
              <% "sessions" -> %>
                <.sessions_tab
                  linked_sessions={@linked_sessions}
                  all_sessions={@all_sessions}
                  search_query={@session_search_query}
                  product_interest={@product_interest}
                />
              <% "stats" -> %>
                <.stats_tab stream_stats={@stream_stats} stream_gmv={@stream_gmv} />
            <% end %>
          </div>
        </div>
      </.modal>
    <% end %>
    """
  end

  @doc """
  Renders the comments tab content.
  """
  attr :comments, :list, required: true
  attr :search_query, :string, default: ""
  attr :has_comments, :boolean, default: false

  def comments_tab(assigns) do
    ~H"""
    <div class="comments-tab">
      <div class="comments-tab__search">
        <.search_input
          value={@search_query}
          on_change="search_comments"
          placeholder="Search comments..."
        />
      </div>

      <div class="comments-list" id="comments-list" phx-update="stream">
        <%= for {dom_id, comment} <- @comments do %>
          <div class="comment-item" id={dom_id}>
            <div class="comment-item__header">
              <span class="comment-item__username">@{comment.tiktok_username}</span>
              <%= if comment.tiktok_nickname && comment.tiktok_nickname != comment.tiktok_username do %>
                <span class="comment-item__nickname">({comment.tiktok_nickname})</span>
              <% end %>
              <span class="comment-item__time">{format_relative_time(comment.commented_at)}</span>
            </div>
            <div class="comment-item__text">{comment.comment_text}</div>
          </div>
        <% end %>
      </div>

      <%= unless @has_comments do %>
        <div class="empty-state">
          <.icon name="hero-chat-bubble-left-right" class="empty-state__icon size-8" />
          <p class="empty-state__title">No comments yet</p>
          <p class="empty-state__description">
            Comments will appear here as they're captured
          </p>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders the sessions tab for linking sessions to streams.
  """
  attr :linked_sessions, :list, default: []
  attr :all_sessions, :list, default: []
  attr :search_query, :string, default: ""
  attr :product_interest, :list, default: []

  def sessions_tab(assigns) do
    ~H"""
    <div class="sessions-tab">
      <div class="sessions-tab__columns">
        <div class="sessions-tab__column">
          <h3 class="sessions-tab__heading">Linked Sessions</h3>

          <%= if Enum.empty?(@linked_sessions) do %>
            <div class="empty-state empty-state--sm">
              <p class="empty-state__title">No sessions linked</p>
              <p class="empty-state__description">
                Link a session to track product mentions in comments
              </p>
            </div>
          <% else %>
            <div class="linked-sessions-list">
              <%= for session <- @linked_sessions do %>
                <div class="linked-session-item">
                  <div class="linked-session-item__info">
                    <span class="linked-session-item__name">{session.name}</span>
                    <span class="linked-session-item__meta">
                      {length(session.session_products)} products
                    </span>
                  </div>
                  <button
                    type="button"
                    class="button button--sm button--ghost-error"
                    phx-click="unlink_session"
                    phx-value-session-id={session.id}
                  >
                    Unlink
                  </button>
                </div>
              <% end %>
            </div>

            <%= if length(@product_interest) > 0 do %>
              <h4 class="sessions-tab__subheading">Product Interest</h4>
              <div class="product-interest-list">
                <%= for item <- @product_interest do %>
                  <div class="product-interest-item">
                    <span class="product-interest-item__number">#{item.product_number}</span>
                    <span class="product-interest-item__name">{item.product_name || "Unknown"}</span>
                    <span class="product-interest-item__count">{item.comment_count} mentions</span>
                  </div>
                <% end %>
              </div>
            <% end %>
          <% end %>
        </div>

        <div class="sessions-tab__column">
          <h3 class="sessions-tab__heading">Link a Session</h3>

          <div class="sessions-tab__search">
            <.search_input
              value={@search_query}
              on_change="search_sessions"
              placeholder="Search sessions..."
            />
          </div>

          <%= if Enum.empty?(@all_sessions) do %>
            <div class="empty-state empty-state--sm">
              <p class="empty-state__description">
                No available sessions found
              </p>
            </div>
          <% else %>
            <div class="available-sessions-list">
              <%= for session <- @all_sessions do %>
                <div class="available-session-item">
                  <div class="available-session-item__info">
                    <span class="available-session-item__name">{session.name}</span>
                    <span class="available-session-item__meta">
                      {length(session.session_products)} products
                    </span>
                  </div>
                  <button
                    type="button"
                    class="button button--sm button--primary"
                    phx-click="link_session"
                    phx-value-session-id={session.id}
                  >
                    Link
                  </button>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders the stats tab with viewer chart.
  """
  attr :stream_stats, :list, required: true
  attr :stream_gmv, :map, default: nil

  def stats_tab(assigns) do
    chart_data = build_chart_data(assigns.stream_stats, assigns.stream_gmv)
    assigns = assign(assigns, :chart_data, chart_data)

    ~H"""
    <div class="stats-tab">
      <%= if Enum.empty?(@stream_stats) do %>
        <div class="empty-state">
          <.icon name="hero-chart-bar" class="empty-state__icon size-8" />
          <p class="empty-state__title">No stats available</p>
          <p class="empty-state__description">
            Stats are recorded every 30 seconds during live streams
          </p>
        </div>
      <% else %>
        <div class="stats-chart-container">
          <canvas
            id="viewer-chart"
            phx-hook="ViewerChart"
            data-chart-data={Jason.encode!(@chart_data)}
          >
          </canvas>
        </div>
        <div class="stats-summary">
          <div class="stats-legend">
            <span class="stats-legend__item stats-legend__item--viewers">
              <span class="stats-legend__color"></span> Viewers
            </span>
            <%= if @stream_gmv && length(@stream_gmv.hourly) > 0 do %>
              <span class="stats-legend__item stats-legend__item--gmv">
                <span class="stats-legend__color"></span> GMV
              </span>
            <% end %>
          </div>
          <p class="text-secondary text-sm">
            {length(@stream_stats)} data points recorded
          </p>
        </div>
      <% end %>
    </div>
    """
  end

  # Helper functions

  # Default TikTok page titles that aren't useful
  @useless_titles [
    "Download TikTok Lite - Make Your Day",
    "TikTok - Make Your Day",
    "TikTok LIVE"
  ]

  defp format_stream_title(%{title: title, started_at: started_at}) do
    if is_nil(title) or title == "" or title in @useless_titles do
      format_stream_date(started_at)
    else
      title
    end
  end

  defp format_stream_date(nil), do: "Stream"

  defp format_stream_date(%DateTime{} = dt) do
    # Convert UTC to PST (UTC-8)
    pst_dt = DateTime.add(dt, -8 * 3600, :second)
    pst_today = DateTime.add(DateTime.utc_now(), -8 * 3600, :second) |> DateTime.to_date()
    date = DateTime.to_date(pst_dt)
    time_str = Calendar.strftime(pst_dt, "%I:%M %p")

    cond do
      date == pst_today ->
        "Today at #{time_str} PST"

      date == Date.add(pst_today, -1) ->
        "Yesterday at #{time_str} PST"

      Date.diff(pst_today, date) < 7 ->
        Calendar.strftime(pst_dt, "%A at ") <> "#{time_str} PST"

      true ->
        Calendar.strftime(pst_dt, "%b %d at ") <> "#{time_str} PST"
    end
  end

  defp format_stream_time(nil), do: "-"

  defp format_stream_time(%DateTime{} = dt) do
    # Convert UTC to PST (UTC-8)
    pst_dt = DateTime.add(dt, -8 * 3600, :second)
    pst_today = DateTime.add(DateTime.utc_now(), -8 * 3600, :second) |> DateTime.to_date()
    date = DateTime.to_date(pst_dt)

    time_str = Calendar.strftime(pst_dt, "%I:%M %p")

    cond do
      date == pst_today ->
        "Today #{time_str} PST"

      date == Date.add(pst_today, -1) ->
        "Yesterday #{time_str} PST"

      Date.diff(pst_today, date) < 7 ->
        Calendar.strftime(pst_dt, "%A ") <> "#{time_str} PST"

      true ->
        Calendar.strftime(pst_dt, "%b %d, %Y")
    end
  end

  defp format_duration(nil, _), do: "-"
  defp format_duration(_, nil), do: "Ongoing"

  defp format_duration(%DateTime{} = started, %DateTime{} = ended) do
    seconds = DateTime.diff(ended, started, :second)
    format_duration_seconds(seconds)
  end

  defp format_duration_seconds(nil), do: "-"

  defp format_duration_seconds(seconds) when is_integer(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m"
      minutes > 0 -> "#{minutes}m"
      true -> "< 1m"
    end
  end

  defp build_chart_data(stats, gmv_data) when is_list(stats) do
    labels =
      Enum.map(stats, fn stat ->
        Calendar.strftime(stat.recorded_at, "%H:%M")
      end)

    viewer_data = Enum.map(stats, & &1.viewer_count)

    datasets = [
      %{
        label: "Viewers",
        data: viewer_data,
        borderColor: "rgb(59, 130, 246)",
        backgroundColor: "rgba(59, 130, 246, 0.1)",
        fill: true,
        tension: 0.3,
        yAxisID: "y"
      }
    ]

    # Add GMV dataset if hourly data is available
    {datasets, has_gmv} =
      if gmv_data && length(gmv_data.hourly) > 0 do
        gmv_by_hour = Map.new(gmv_data.hourly, fn h -> {h.hour, h.gmv_cents} end)

        # Replicate GMV value across all data points within each hour
        # This creates a stepped line effect where GMV is constant per hour
        gmv_data_points =
          Enum.map(stats, fn stat ->
            hour = DateTime.truncate(stat.recorded_at, :second)
            hour = %{hour | minute: 0, second: 0}
            Map.get(gmv_by_hour, hour, 0) / 100
          end)

        gmv_dataset = %{
          label: "GMV",
          data: gmv_data_points,
          borderColor: "rgb(34, 197, 94)",
          backgroundColor: "transparent",
          borderDash: [5, 5],
          stepped: true,
          fill: false,
          tension: 0,
          pointRadius: 0,
          yAxisID: "y1"
        }

        {datasets ++ [gmv_dataset], true}
      else
        {datasets, false}
      end

    %{labels: labels, datasets: datasets, hasGmv: has_gmv}
  end
end
