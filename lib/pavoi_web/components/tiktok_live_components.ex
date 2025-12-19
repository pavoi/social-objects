defmodule PavoiWeb.TiktokLiveComponents do
  @moduledoc """
  Reusable components for TikTok Live stream browsing.
  """
  use Phoenix.Component

  import PavoiWeb.CoreComponents
  import PavoiWeb.ViewHelpers

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
  Renders the streams table.
  """
  attr :streams, :list, required: true
  attr :on_row_click, :string, default: nil

  def streams_table(assigns) do
    ~H"""
    <div class="streams-table-wrapper">
      <table id="streams-table" class="streams-table" phx-hook="ColumnResize" data-table-id="streams">
        <thead>
          <tr>
            <th data-column-id="title">Title</th>
            <th data-column-id="status">Status</th>
            <th data-column-id="started">Started</th>
            <th data-column-id="duration">Duration</th>
            <th data-column-id="viewers">Viewers</th>
            <th data-column-id="comments">Comments</th>
          </tr>
        </thead>
        <tbody>
          <%= for stream <- @streams do %>
            <tr
              phx-click={@on_row_click}
              phx-value-id={stream.id}
              class={[@on_row_click && "cursor-pointer hover:bg-hover"]}
            >
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
            <div class="stream-modal-header__title">
              <h2 class="modal__title">{format_stream_title(@stream)}</h2>
              <span class="text-secondary">@{@stream.unique_id}</span>
            </div>
            <div class="stream-modal-header__status">
              <.stream_status_badge status={@stream.status} />
              <span class="text-secondary text-sm">
                Started {format_relative_time(@stream.started_at)}
              </span>
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
              class={["tab", @active_tab == "stats" && "tab--active"]}
              phx-click="change_tab"
              phx-value-tab="stats"
            >
              Stats
            </button>
            <button
              type="button"
              class={["tab", @active_tab == "raw" && "tab--active"]}
              phx-click="change_tab"
              phx-value-tab="raw"
            >
              Raw Data
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
              <% "stats" -> %>
                <.stats_tab stream_stats={@stream_stats} />
              <% "raw" -> %>
                <.raw_data_tab metadata={@stream.raw_metadata} />
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
  Renders the stats tab with viewer chart.
  """
  attr :stream_stats, :list, required: true

  def stats_tab(assigns) do
    chart_data = build_chart_data(assigns.stream_stats)
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
          <p class="text-secondary text-sm">
            {length(@stream_stats)} data points recorded
          </p>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders the raw data tab with JSON viewer.
  """
  attr :metadata, :map, required: true

  def raw_data_tab(assigns) do
    formatted_json = Jason.encode!(assigns.metadata, pretty: true)
    assigns = assign(assigns, :formatted_json, formatted_json)

    ~H"""
    <div class="raw-data-tab">
      <pre class="json-viewer"><code>{@formatted_json}</code></pre>
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

  defp build_chart_data(stats) when is_list(stats) do
    labels =
      Enum.map(stats, fn stat ->
        Calendar.strftime(stat.recorded_at, "%H:%M")
      end)

    viewer_data = Enum.map(stats, & &1.viewer_count)

    %{
      labels: labels,
      datasets: [
        %{
          label: "Viewers",
          data: viewer_data,
          borderColor: "rgb(59, 130, 246)",
          backgroundColor: "rgba(59, 130, 246, 0.1)",
          fill: true,
          tension: 0.3
        }
      ]
    }
  end
end
