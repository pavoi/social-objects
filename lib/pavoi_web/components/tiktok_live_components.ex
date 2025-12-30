defmodule PavoiWeb.TiktokLiveComponents do
  @moduledoc """
  Reusable components for TikTok Live stream browsing.
  """
  use Phoenix.Component

  import PavoiWeb.CoreComponents
  import PavoiWeb.CreatorTableComponents, only: [sort_header: 1]
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
  Renders the product count for a stream's linked session.

  Shows the number of products if a session is linked,
  or a "Link session" indicator if not.
  """
  attr :stream, :any, required: true

  def stream_product_count(assigns) do
    product_count =
      case assigns.stream.session do
        %{session_products: products} when is_list(products) -> length(products)
        _ -> nil
      end

    assigns = assign(assigns, :product_count, product_count)

    ~H"""
    <%= if @product_count do %>
      <span class="stream-product-count">{@product_count}</span>
    <% else %>
      <button
        type="button"
        class="stream-link-session-btn"
        phx-click="navigate_to_stream"
        phx-value-id={@stream.id}
        phx-value-tab="sessions"
      >
        Link session
      </button>
    <% end %>
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
  attr :streams_sentiment, :map, default: %{}

  def streams_table(assigns) do
    ~H"""
    <div class="streams-table-wrapper">
      <table id="streams-table" class="streams-table" phx-hook="ColumnResize" data-table-id="streams">
        <thead>
          <tr>
            <th data-column-id="thumbnail"></th>
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
            />
            <.sort_header
              label="Viewers"
              field="viewers"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
            />
            <th data-column-id="products">Products</th>
            <.sort_header
              label="GMV"
              field="gmv"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
            />
            <.sort_header
              label="Comments"
              field="comments"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
            />
            <th data-column-id="sentiment">Sentiment</th>
          </tr>
        </thead>
        <tbody>
          <%= for stream <- @streams do %>
            <tr
              phx-click={@on_row_click}
              phx-value-id={stream.id}
              class={[@on_row_click && "cursor-pointer hover:bg-hover"]}
            >
              <td data-column-id="thumbnail">
                <.stream_thumbnail url={Stream.cover_image_url(stream)} />
              </td>
              <td data-column-id="title">
                <div class="streams-table__title">
                  <span class="streams-table__title-text">{format_stream_title(stream)}</span>
                  <%= if stream.status == :capturing do %>
                    <a
                      href={"https://www.tiktok.com/@#{stream.unique_id}/live"}
                      target="_blank"
                      class="streams-table__username streams-table__username--link"
                      onclick="event.stopPropagation()"
                    >
                      @{stream.unique_id}
                    </a>
                  <% else %>
                    <span class="streams-table__username">@{stream.unique_id}</span>
                  <% end %>
                </div>
              </td>
              <td data-column-id="status">
                <.stream_status_badge status={stream.status} />
              </td>
              <td data-column-id="started" class="text-secondary">
                {format_stream_time(stream.started_at)}
              </td>
              <td data-column-id="duration" class="text-right text-secondary">
                {format_duration(stream.started_at, stream.ended_at)}
              </td>
              <td data-column-id="viewers" class="text-right">
                <%= if stream.status == :capturing do %>
                  <span class="text-live">{format_number(stream.viewer_count_current)}</span>
                <% else %>
                  {format_number(stream.viewer_count_peak)}
                <% end %>
              </td>
              <td data-column-id="products" class="text-right">
                <.stream_product_count stream={stream} />
              </td>
              <td data-column-id="gmv" class="text-right">
                <%= if stream.gmv_cents do %>
                  <span class="text-green-500">{format_gmv(stream.gmv_cents)}</span>
                <% else %>
                  <span class="text-secondary">—</span>
                <% end %>
              </td>
              <td data-column-id="comments" class="text-right">{format_number(stream.total_comments)}</td>
              <td data-column-id="sentiment" class="text-center">
                <.stream_sentiment_indicator sentiment={Map.get(@streams_sentiment, stream.id)} />
              </td>
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
                  <%= if @stream.status == :capturing do %>
                    <a
                      href={"https://www.tiktok.com/@#{@stream.unique_id}/live"}
                      target="_blank"
                      class="stream-modal-header__username-link"
                    >
                      @{@stream.unique_id}
                    </a>
                  <% else %>
                    <span class="text-secondary">@{@stream.unique_id}</span>
                  <% end %>
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
              class={["tab", @active_tab == "stats" && "tab--active"]}
              phx-click="change_tab"
              phx-value-tab="stats"
            >
              Stats
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
            role="img"
            aria-label="Viewer count over time chart"
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

  @doc """
  Renders page-level tabs for Streams/Analytics navigation.
  """
  attr :active_tab, :string, default: "streams"

  def page_tabs(assigns) do
    ~H"""
    <div class="page-tabs">
      <button
        type="button"
        class={["page-tab", @active_tab == "streams" && "page-tab--active"]}
        phx-click="change_page_tab"
        phx-value-tab="streams"
      >
        Streams
      </button>
      <button
        type="button"
        class={["page-tab", @active_tab == "analytics" && "page-tab--active"]}
        phx-click="change_page_tab"
        phx-value-tab="analytics"
      >
        Analytics
      </button>
    </div>
    """
  end

  @doc """
  Renders the full analytics tab with charts and comments table.
  """
  attr :stream_id, :integer, default: nil
  attr :streams, :list, default: []
  attr :sentiment_breakdown, :map, default: nil
  attr :category_breakdown, :list, default: []
  # Pre-computed JSON strings to prevent chart re-renders when filters change
  attr :sentiment_chart_json, :string, default: nil
  attr :category_chart_json, :string, default: nil
  attr :comments, :list, default: []
  attr :comments_total, :integer, default: 0
  attr :has_more, :boolean, default: false
  attr :search_query, :string, default: ""
  attr :sentiment_filter, :atom, default: nil
  attr :category_filter, :atom, default: nil
  attr :loading, :boolean, default: false

  def analytics_tab(assigns) do
    # Check if charts have data (for conditional rendering)
    has_sentiment_data = assigns.sentiment_breakdown && assigns.sentiment_breakdown.total > 0
    has_category_data = length(assigns.category_breakdown) > 0

    assigns =
      assigns
      |> assign(:has_sentiment_data, has_sentiment_data)
      |> assign(:has_category_data, has_category_data)

    ~H"""
    <div class="analytics-tab">
      <div class="analytics-tab__header">
        <span class="analytics-tab__header-label">Showing analytics for:</span>
        <form phx-change="analytics_select_stream">
          <select name="stream_id" class="filter-select analytics-tab__stream-select">
            <option value="" selected={is_nil(@stream_id)}>All Streams</option>
            <%= for stream <- @streams do %>
              <option value={stream.id} selected={@stream_id == stream.id}>
                {format_stream_option(stream)}
              </option>
            <% end %>
          </select>
        </form>
      </div>

      <%!--
        Charts section uses phx-update="ignore" to prevent LiveView from patching it
        when comment filters/search/pagination change. The ID includes the stream_id so
        that when the stream selector changes, a NEW element is created (triggering fresh
        hook mounts with new data). Simple conditional rendering is used since the
        ignored section won't be patched anyway.
      --%>
      <div
        id={"analytics-charts-#{@stream_id || "all"}"}
        class="analytics-tab__charts"
        phx-update="ignore"
      >
        <div class="analytics-chart-card analytics-chart-card--sentiment">
          <h3 class="analytics-chart-card__title">Sentiment</h3>
          <div class="analytics-chart-card__chart-wrapper">
            <%= if @has_sentiment_data do %>
              <div class="analytics-chart-card__chart">
                <canvas
                  id={"sentiment-chart-#{@stream_id || "all"}"}
                  phx-hook="SentimentChart"
                  data-chart-data={@sentiment_chart_json || "{}"}
                  role="img"
                  aria-label="Comment sentiment breakdown chart"
                >
                </canvas>
              </div>
            <% else %>
              <div class="analytics-chart-card__empty">
                No classified comments
              </div>
            <% end %>
          </div>
        </div>

        <div class="analytics-chart-card analytics-chart-card--categories">
          <h3 class="analytics-chart-card__title">Comment Categories</h3>
          <div class="analytics-chart-card__chart-wrapper">
            <%= if @has_category_data do %>
              <div class="analytics-chart-card__chart">
                <canvas
                  id={"category-chart-#{@stream_id || "all"}"}
                  phx-hook="CategoryChart"
                  data-chart-data={@category_chart_json || "{}"}
                  role="img"
                  aria-label="Comment categories breakdown chart"
                >
                </canvas>
              </div>
            <% else %>
              <div class="analytics-chart-card__empty">
                No classified comments
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <.analytics_comments_table
        comments={@comments}
        total={@comments_total}
        has_more={@has_more}
        search_query={@search_query}
        sentiment_filter={@sentiment_filter}
        category_filter={@category_filter}
        show_stream_column={is_nil(@stream_id)}
        loading={@loading}
      />
    </div>
    """
  end

  @doc """
  Renders the analytics comments table with filters.
  """
  attr :comments, :list, default: []
  attr :total, :integer, default: 0
  attr :has_more, :boolean, default: false
  attr :search_query, :string, default: ""
  attr :sentiment_filter, :atom, default: nil
  attr :category_filter, :atom, default: nil
  attr :show_stream_column, :boolean, default: true
  attr :loading, :boolean, default: false

  def analytics_comments_table(assigns) do
    ~H"""
    <div class="analytics-comments">
      <div class="analytics-comments__header">
        <h3 class="analytics-comments__title">Comments</h3>
        <span class="analytics-comments__count">({format_number(@total)})</span>

        <div class="analytics-comments__filters">
          <div class="analytics-comments__search">
            <.search_input
              value={@search_query}
              on_change="analytics_search"
              placeholder="Search comments..."
            />
          </div>

          <form phx-change="analytics_filter_sentiment">
            <select name="sentiment" class="filter-select">
              <option value="" selected={is_nil(@sentiment_filter)}>All Sentiment</option>
              <option value="positive" selected={@sentiment_filter == :positive}>Positive</option>
              <option value="neutral" selected={@sentiment_filter == :neutral}>Neutral</option>
              <option value="negative" selected={@sentiment_filter == :negative}>Negative</option>
            </select>
          </form>

          <form phx-change="analytics_filter_category">
            <select name="category" class="filter-select">
              <option value="" selected={is_nil(@category_filter)}>All Categories</option>
              <option value="praise_compliment" selected={@category_filter == :praise_compliment}>
                Praise
              </option>
              <option value="question_confusion" selected={@category_filter == :question_confusion}>
                Questions
              </option>
              <option value="product_request" selected={@category_filter == :product_request}>
                Product Requests
              </option>
              <option value="concern_complaint" selected={@category_filter == :concern_complaint}>
                Concerns
              </option>
              <option value="technical_issue" selected={@category_filter == :technical_issue}>
                Technical Issues
              </option>
              <option value="flash_sale" selected={@category_filter == :flash_sale}>
                Flash Sale
              </option>
              <option value="general" selected={@category_filter == :general}>General</option>
            </select>
          </form>
        </div>
      </div>

      <%= if Enum.empty?(@comments) do %>
        <div class="analytics-comments__empty">
          No comments found matching your filters
        </div>
      <% else %>
        <div
          id="analytics-comments-list"
          class="analytics-comments-scroll-container"
          phx-viewport-bottom={@has_more && !@loading && "analytics_load_more"}
        >
          <table class="analytics-comments-table">
            <thead>
              <tr>
                <th>Comment</th>
                <th>User</th>
                <%= if @show_stream_column do %>
                  <th>Stream</th>
                <% end %>
                <th>Sentiment</th>
                <th>Category</th>
              </tr>
            </thead>
            <tbody>
              <%= for comment <- @comments do %>
                <tr>
                  <td class="analytics-comments-table__comment" title={comment.comment_text}>
                    {comment.comment_text}
                  </td>
                  <td class="analytics-comments-table__user">@{comment.tiktok_username}</td>
                  <%= if @show_stream_column do %>
                    <td class="analytics-comments-table__stream">
                      <%= if comment.stream do %>
                        <button
                          type="button"
                          class="analytics-comments-table__stream-link"
                          phx-click="navigate_to_stream"
                          phx-value-id={comment.stream.id}
                        >
                          {format_stream_option(comment.stream)}
                        </button>
                      <% else %>
                        <span class="text-tertiary">Unknown</span>
                      <% end %>
                    </td>
                  <% end %>
                  <td>
                    <.sentiment_badge sentiment={comment.sentiment} />
                  </td>
                  <td>
                    <.category_badge category={comment.category} />
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>

          <%= if @loading do %>
            <div class="analytics-comments-loading">
              <div class="spinner"></div>
              <span>Loading more comments...</span>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a sentiment badge.
  """
  attr :sentiment, :atom, default: nil

  def sentiment_badge(assigns) do
    {label, class} =
      case assigns.sentiment do
        :positive -> {"Positive", "sentiment-badge--positive"}
        :neutral -> {"Neutral", "sentiment-badge--neutral"}
        :negative -> {"Negative", "sentiment-badge--negative"}
        _ -> {"—", ""}
      end

    assigns = assign(assigns, label: label, class: class)

    ~H"""
    <span class={["sentiment-badge", @class]}>{@label}</span>
    """
  end

  @doc """
  Renders a category badge.
  """
  attr :category, :atom, default: nil

  def category_badge(assigns) do
    {label, class} =
      case assigns.category do
        :praise_compliment -> {"Praise", "category-badge--praise_compliment"}
        :question_confusion -> {"Question", "category-badge--question_confusion"}
        :product_request -> {"Product Request", "category-badge--product_request"}
        :concern_complaint -> {"Concern", "category-badge--concern_complaint"}
        :technical_issue -> {"Technical", "category-badge--technical_issue"}
        :flash_sale -> {"Flash Sale", "category-badge--flash_sale"}
        :general -> {"General", "category-badge--general"}
        _ -> {"—", ""}
      end

    assigns = assign(assigns, label: label, class: class)

    ~H"""
    <span class={["category-badge", @class]}>{@label}</span>
    """
  end

  @doc """
  Renders a mini sentiment bar for the streams table.
  """
  attr :sentiment, :map, default: nil

  def stream_sentiment_indicator(assigns) do
    ~H"""
    <%= if @sentiment && (@sentiment.positive_percent > 0 || @sentiment.negative_percent > 0) do %>
      <div
        class="stream-sentiment-mini"
        title={"#{@sentiment.positive_percent}% positive, #{@sentiment.negative_percent}% negative"}
      >
        <div class="stream-sentiment-mini__positive" style={"width: #{@sentiment.positive_percent}%"}>
        </div>
        <div
          class="stream-sentiment-mini__neutral"
          style={"width: #{100 - @sentiment.positive_percent - @sentiment.negative_percent}%"}
        >
        </div>
        <div class="stream-sentiment-mini__negative" style={"width: #{@sentiment.negative_percent}%"}>
        </div>
      </div>
    <% else %>
      <div class="stream-sentiment-mini stream-sentiment-mini--empty"></div>
    <% end %>
    """
  end

  # Chart data building functions moved to LiveView for stable rendering
  # (see lib/pavoi_web/live/tiktok_live/index.ex - build_sentiment_chart_json/1, build_category_chart_json/1)

  defp format_stream_option(nil), do: "Unknown"

  defp format_stream_option(%{unique_id: unique_id, started_at: started_at}) do
    date_str =
      if started_at do
        Calendar.strftime(started_at, "%b %d")
      else
        "No date"
      end

    "@#{unique_id} - #{date_str}"
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
