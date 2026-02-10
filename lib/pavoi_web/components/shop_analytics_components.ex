defmodule PavoiWeb.ShopAnalyticsComponents do
  @moduledoc """
  Reusable UI components for the Shop Analytics dashboard.
  """

  use Phoenix.Component

  @doc """
  Renders a stat card with a value and optional delta indicator.

  ## Examples

      <.stat_card_with_delta
        label="GMV"
        value="$1,234,567"
        delta={12.5}
        loading={false}
      />
  """
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :delta, :float, default: nil, doc: "Percentage change from previous period"
  attr :loading, :boolean, default: false
  attr :format, :atom, default: :default, doc: "Format type: :default, :currency, :percentage"

  def stat_card_with_delta(assigns) do
    ~H"""
    <div class="analytics-stat-card">
      <div class="analytics-stat-card__label">{@label}</div>
      <%= if @loading do %>
        <div class="analytics-stat-card__value analytics-stat-card__value--loading">
          <span class="analytics-stat-card__skeleton"></span>
        </div>
      <% else %>
        <div class="analytics-stat-card__value">{@value}</div>
        <.delta_indicator :if={@delta} delta={@delta} />
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a delta indicator showing percentage change with a trend arrow.

  ## Examples

      <.delta_indicator delta={12.5} />
      <.delta_indicator delta={-3.2} />
  """
  attr :delta, :float, required: true

  def delta_indicator(assigns) do
    ~H"""
    <div class={[
      "delta-indicator",
      @delta >= 0 && "delta-indicator--positive",
      @delta < 0 && "delta-indicator--negative"
    ]}>
      <svg
        :if={@delta >= 0}
        class="delta-indicator__icon"
        viewBox="0 0 20 20"
        fill="currentColor"
      >
        <path
          fill-rule="evenodd"
          d="M10 17a.75.75 0 01-.75-.75V5.612L5.29 9.77a.75.75 0 01-1.08-1.04l5.25-5.5a.75.75 0 011.08 0l5.25 5.5a.75.75 0 11-1.08 1.04l-3.96-4.158V16.25A.75.75 0 0110 17z"
          clip-rule="evenodd"
        />
      </svg>
      <svg
        :if={@delta < 0}
        class="delta-indicator__icon"
        viewBox="0 0 20 20"
        fill="currentColor"
      >
        <path
          fill-rule="evenodd"
          d="M10 3a.75.75 0 01.75.75v10.638l3.96-4.158a.75.75 0 111.08 1.04l-5.25 5.5a.75.75 0 01-1.08 0l-5.25-5.5a.75.75 0 111.08-1.04l3.96 4.158V3.75A.75.75 0 0110 3z"
          clip-rule="evenodd"
        />
      </svg>
      <span class="delta-indicator__value">{format_delta(@delta)}%</span>
    </div>
    """
  end

  defp format_delta(delta) when delta >= 0, do: "+#{Float.round(delta, 1)}"
  defp format_delta(delta), do: Float.round(delta, 1)

  @doc """
  Renders a date range filter with preset buttons and optional custom date picker.

  ## Examples

      <.date_range_filter preset="30d" />
  """
  attr :preset, :string, required: true, doc: "Current selected preset: 7d, 30d, 90d"

  def date_range_filter(assigns) do
    ~H"""
    <div class="date-range-filter">
      <button
        type="button"
        phx-click="filter_date"
        phx-value-preset="7d"
        class={[
          "date-range-filter__button",
          @preset == "7d" && "date-range-filter__button--active"
        ]}
      >
        7 Days
      </button>
      <button
        type="button"
        phx-click="filter_date"
        phx-value-preset="30d"
        class={[
          "date-range-filter__button",
          @preset == "30d" && "date-range-filter__button--active"
        ]}
      >
        30 Days
      </button>
      <button
        type="button"
        phx-click="filter_date"
        phx-value-preset="90d"
        class={[
          "date-range-filter__button",
          @preset == "90d" && "date-range-filter__button--active"
        ]}
      >
        90 Days
      </button>
    </div>
    """
  end

  @doc """
  Renders a chart card container with title.

  ## Examples

      <.chart_card title="Channel Breakdown">
        <canvas id="channel-chart" phx-hook="ChannelBreakdownChart" />
      </.chart_card>
  """
  attr :title, :string, required: true
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def chart_card(assigns) do
    ~H"""
    <div class={["analytics-chart-card", @class]}>
      <h3 class="analytics-chart-card__title">{@title}</h3>
      <div class="analytics-chart-card__content">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  Renders a loading spinner.
  """
  def loading_spinner(assigns) do
    ~H"""
    <div class="analytics-loading">
      <div class="analytics-loading__spinner"></div>
      <span class="analytics-loading__text">Loading analytics...</span>
    </div>
    """
  end

  @doc """
  Renders an error state with appropriate message and actions based on error type.
  """
  attr :message, :string, default: "Failed to load analytics data"
  attr :error_type, :atom, default: :general

  def error_state(assigns) do
    ~H"""
    <div class={["analytics-error", error_type_class(@error_type)]}>
      <.error_icon error_type={@error_type} />
      <p class="analytics-error__message">{@message}</p>
      <.error_actions error_type={@error_type} />
    </div>
    """
  end

  defp error_type_class(:scope_required), do: "analytics-error--warning"
  defp error_type_class(:not_connected), do: "analytics-error--info"
  defp error_type_class(_), do: ""

  defp error_icon(%{error_type: :scope_required} = assigns) do
    ~H"""
    <svg
      class="analytics-error__icon analytics-error__icon--warning"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
    >
      <path d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
    </svg>
    """
  end

  defp error_icon(%{error_type: :not_connected} = assigns) do
    ~H"""
    <svg
      class="analytics-error__icon analytics-error__icon--info"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
    >
      <path d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1" />
    </svg>
    """
  end

  defp error_icon(assigns) do
    ~H"""
    <svg
      class="analytics-error__icon"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
    >
      <circle cx="12" cy="12" r="10" />
      <line x1="12" y1="8" x2="12" y2="12" />
      <line x1="12" y1="16" x2="12.01" y2="16" />
    </svg>
    """
  end

  defp error_actions(%{error_type: :scope_required} = assigns) do
    ~H"""
    <div class="analytics-error__actions">
      <p class="analytics-error__hint">
        The TikTok Shop app requires the <code>data.shop_analytics.public.read</code> scope.
      </p>
    </div>
    """
  end

  defp error_actions(%{error_type: :not_connected} = assigns) do
    ~H"""
    <div class="analytics-error__actions">
      <p class="analytics-error__hint">
        Connect your TikTok Shop account in brand settings to access analytics.
      </p>
    </div>
    """
  end

  defp error_actions(%{error_type: :rate_limited} = assigns) do
    ~H"""
    <div class="analytics-error__actions">
      <button type="button" phx-click="retry_load" class="button button--outline button--sm">
        Try Again
      </button>
    </div>
    """
  end

  defp error_actions(assigns) do
    ~H"""
    <div class="analytics-error__actions">
      <button type="button" phx-click="retry_load" class="button button--outline button--sm">
        Retry
      </button>
    </div>
    """
  end

  @doc """
  Renders an empty state message.
  """
  attr :message, :string, default: "No data available for the selected period"

  def empty_state(assigns) do
    ~H"""
    <div class="analytics-empty">
      <svg
        class="analytics-empty__icon"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.5"
      >
        <path d="M3 13.125C3 12.504 3.504 12 4.125 12h2.25c.621 0 1.125.504 1.125 1.125v6.75C7.5 20.496 6.996 21 6.375 21h-2.25A1.125 1.125 0 013 19.875v-6.75z" />
        <path d="M9.75 8.625c0-.621.504-1.125 1.125-1.125h2.25c.621 0 1.125.504 1.125 1.125v11.25c0 .621-.504 1.125-1.125 1.125h-2.25a1.125 1.125 0 01-1.125-1.125V8.625z" />
        <path d="M16.5 4.125c0-.621.504-1.125 1.125-1.125h2.25C20.496 3 21 3.504 21 4.125v15.75c0 .621-.504 1.125-1.125 1.125h-2.25a1.125 1.125 0 01-1.125-1.125V4.125z" />
      </svg>
      <p class="analytics-empty__message">{@message}</p>
    </div>
    """
  end
end
