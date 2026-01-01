defmodule PavoiWeb.ReadmeLive.Index do
  @moduledoc """
  LiveView for the application documentation/directory page.

  Provides an overview of all pages, features, and integrations with live stats.
  """
  use PavoiWeb, :live_view

  import Ecto.Query

  on_mount {PavoiWeb.NavHooks, :set_current_page}

  alias Pavoi.Catalog.Product
  alias Pavoi.Communications.{Email, Slack}
  alias Pavoi.Creators
  alias Pavoi.Outreach.OutreachLog
  alias Pavoi.Repo
  alias Pavoi.Sessions.Session
  alias Pavoi.Settings
  alias Pavoi.TiktokLive
  alias Pavoi.TiktokLive.{BridgeHealthMonitor, Stream}

  @impl true
  def mount(_params, _session, socket) do
    # Fetch counts for stats display
    stats = %{
      sessions: Repo.aggregate(Session, :count),
      products: Repo.aggregate(Product, :count),
      creators: Creators.count_creators(),
      streams: TiktokLive.count_streams()
    }

    # Fetch integration statuses
    integrations = %{
      shopify: %{
        last_sync: Settings.get_shopify_last_sync_at()
      },
      tiktok_shop: %{
        last_sync: Settings.get_tiktok_last_sync_at()
      },
      bigquery: %{
        last_sync: Settings.get_bigquery_last_sync_at()
      },
      tiktok_bridge: get_bridge_status(),
      openai: %{
        configured: openai_configured?()
      },
      sendgrid: %{
        configured: Email.configured?(),
        last_sent: get_last_email_sent()
      },
      slack: %{
        configured: Slack.configured?(),
        last_report: get_last_slack_report()
      }
    }

    {:ok,
     socket
     |> assign(:page_title, "Readme")
     |> assign(:stats, stats)
     |> assign(:integrations, integrations)}
  end

  defp get_bridge_status do
    case BridgeHealthMonitor.status() do
      {:error, :not_running} ->
        %{healthy: nil, last_healthy_at: nil, last_scan: Settings.get_tiktok_live_last_scan_at()}

      %{healthy: healthy, last_healthy_at: last_healthy_at} ->
        %{
          healthy: healthy,
          last_healthy_at: last_healthy_at,
          last_scan: Settings.get_tiktok_live_last_scan_at()
        }
    end
  end

  defp openai_configured? do
    key = Application.get_env(:pavoi, :openai_api_key)
    is_binary(key) && key != ""
  end

  defp get_last_email_sent do
    OutreachLog
    |> where([ol], ol.status == "sent")
    |> order_by([ol], desc: ol.sent_at)
    |> limit(1)
    |> select([ol], ol.sent_at)
    |> Repo.one()
  end

  defp get_last_slack_report do
    Stream
    |> where([s], not is_nil(s.report_sent_at))
    |> order_by([s], desc: s.report_sent_at)
    |> limit(1)
    |> select([s], s.report_sent_at)
    |> Repo.one()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.nav_tabs current_page={@current_page} />

    <div class="readme-page">
      <section class="readme-section">
        <h2 class="readme-section__title">Pages</h2>
        <div class="readme-cards readme-cards--pages">
          <.page_card
            emoji="🎬"
            title="Sessions"
            description="Create and manage live streaming sessions with curated product lineups"
            href={~p"/sessions"}
            stat={@stats.sessions}
            stat_label="sessions"
          >
            <:features>
              <li>Host view for displaying products during live streams</li>
              <li>Mobile controller for navigation and messaging</li>
              <li>AI-generated talking points per product</li>
              <li>Session duplication for quick setup</li>
            </:features>
          </.page_card>

          <.page_card
            emoji="📺"
            title="Streams"
            description="Capture and analyze TikTok Live stream data in real-time"
            href={~p"/streams"}
            stat={@stats.streams}
            stat_label="streams captured"
          >
            <:features>
              <li>Real-time comment capture during live streams</li>
              <li>AI sentiment classification (positive/neutral/negative)</li>
              <li>Comment categorization (praise, questions, requests, etc.)</li>
              <li>Viewer metrics and engagement tracking</li>
              <li>GMV and sales analytics</li>
            </:features>
          </.page_card>

          <.page_card
            emoji="👥"
            title="Creators"
            description="Manage creator relationships and run outreach campaigns"
            href={~p"/creators"}
            stat={@stats.creators}
            stat_label="creators"
          >
            <:features>
              <li>Creator CRM with performance tracking (GMV, ROI)</li>
              <li>Tag-based organization and filtering</li>
              <li>Email template builder with variables</li>
              <li>Batch email outreach campaigns</li>
              <li>Delivery tracking via SendGrid webhooks</li>
            </:features>
          </.page_card>

          <.page_card
            emoji="📦"
            title="Products"
            description="Unified product catalog from Shopify and TikTok Shop"
            href={~p"/products"}
            stat={@stats.products}
            stat_label="products"
          >
            <:features>
              <li>Automatic sync from Shopify and TikTok Shop</li>
              <li>AI-generated talking points for each product</li>
              <li>Price and image management</li>
              <li>Search and filter by platform, name, SKU</li>
            </:features>
          </.page_card>
        </div>
      </section>

      <section class="readme-section">
        <h2 class="readme-section__title">Integrations</h2>
        <div class="readme-cards readme-cards--integrations">
          <.integration_card
            title="Shopify"
            logo="shopify.svg"
            status={:ok}
            status_text={format_last_sync(@integrations.shopify.last_sync)}
          >
            <li>Product catalog sync via GraphQL API</li>
            <li>Brand and collection import</li>
            <li>Image handling with S3 storage</li>
          </.integration_card>

          <.integration_card
            title="TikTok Shop"
            logo="tiktok.svg"
            status={:ok}
            status_text={format_last_sync(@integrations.tiktok_shop.last_sync)}
          >
            <li>OAuth 2.0 service account authentication</li>
            <li>Product catalog access</li>
            <li>Shop credentials management</li>
          </.integration_card>

          <.integration_card
            title="BigQuery"
            logo="bigquery.svg"
            status={:ok}
            status_text={format_last_sync(@integrations.bigquery.last_sync)}
          >
            <li>Creator performance data (GMV, purchases)</li>
            <li>Order history and analytics</li>
            <li>JWT-based service account auth</li>
          </.integration_card>

          <.integration_card
            title="TikTok Live Bridge"
            logo="tiktok-bridge.svg"
            status={bridge_status(@integrations.tiktok_bridge)}
            status_text={bridge_status_text(@integrations.tiktok_bridge)}
          >
            <li>Custom Node.js bridge service</li>
            <li>WebSocket connection to TikTok WebCast</li>
            <li>Real-time: comments, gifts, likes, viewers</li>
            <li>Stream status detection via page scraping</li>
          </.integration_card>

          <.integration_card
            title="OpenAI"
            logo="openai.svg"
            status={if @integrations.openai.configured, do: :ok, else: :not_configured}
            status_text={if @integrations.openai.configured, do: "Configured", else: "Not configured"}
          >
            <li>Product talking points generation</li>
            <li>Comment sentiment classification</li>
            <li>Comment categorization (7 categories)</li>
          </.integration_card>

          <.integration_card
            title="SendGrid"
            logo="sendgrid.svg"
            status={if @integrations.sendgrid.configured, do: :ok, else: :not_configured}
            status_text={
              format_last_activity(
                "Sent",
                @integrations.sendgrid.last_sent,
                @integrations.sendgrid.configured
              )
            }
          >
            <li>Transactional email delivery</li>
            <li>Webhook integration for events</li>
            <li>Open/click/bounce tracking</li>
          </.integration_card>

          <.integration_card
            title="Slack"
            logo="slack.svg"
            status={if @integrations.slack.configured, do: :ok, else: :not_configured}
            status_text={
              format_last_activity(
                "Report",
                @integrations.slack.last_report,
                @integrations.slack.configured
              )
            }
          >
            <li>Stream report notifications</li>
            <li>Post-stream analytics summaries</li>
          </.integration_card>
        </div>
      </section>
    </div>
    """
  end

  # Components

  attr :emoji, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :href, :string, required: true
  attr :stat, :integer, required: true
  attr :stat_label, :string, required: true
  slot :features, required: true

  defp page_card(assigns) do
    ~H"""
    <.link href={@href} class="readme-card readme-card--page">
      <div class="readme-card__header">
        <h3 class="readme-card__title">
          <span class="readme-card__emoji">{@emoji}</span>
          {@title}
        </h3>
        <span class="readme-card__stat">
          {format_number(@stat)} {@stat_label}
        </span>
      </div>
      <p class="readme-card__description">{@description}</p>
      <ul class="readme-card__features">
        {render_slot(@features)}
      </ul>
    </.link>
    """
  end

  attr :title, :string, required: true
  attr :logo, :string, required: true
  attr :status, :atom, required: true
  attr :status_text, :string, required: true
  slot :inner_block, required: true

  defp integration_card(assigns) do
    ~H"""
    <div class="readme-card readme-card--integration">
      <div class="readme-card__integration-header">
        <img
          src={PavoiWeb.Endpoint.static_path("/images/integrations/#{@logo}")}
          alt={@title}
          class="readme-card__logo"
        />
        <h3 class="readme-card__title">{@title}</h3>
      </div>
      <ul class="readme-card__features">
        {render_slot(@inner_block)}
      </ul>
      <div class={"readme-card__status readme-card__status--#{@status}"}>
        <span class="readme-card__status-dot"></span>
        <span class="readme-card__status-text">{@status_text}</span>
      </div>
    </div>
    """
  end

  # Formatting helpers

  defp format_number(num) when num >= 1000 do
    "#{Float.round(num / 1000, 1)}k"
  end

  defp format_number(num), do: Integer.to_string(num)

  defp format_last_sync(nil), do: "Never synced"

  defp format_last_sync(datetime) do
    "Synced #{relative_time(datetime)}"
  end

  defp format_last_activity(_label, _datetime, false), do: "Not configured"
  defp format_last_activity(_label, nil, true), do: "No activity yet"

  defp format_last_activity(label, datetime, true) do
    "#{label} #{relative_time(datetime)}"
  end

  defp relative_time(datetime) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, datetime)

    cond do
      diff_seconds < 60 -> "just now"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m ago"
      diff_seconds < 86_400 -> "#{div(diff_seconds, 3600)}h ago"
      diff_seconds < 604_800 -> "#{div(diff_seconds, 86_400)}d ago"
      true -> Calendar.strftime(datetime, "%b %d")
    end
  end

  defp bridge_status(%{healthy: nil}), do: :not_configured
  defp bridge_status(%{healthy: true}), do: :ok
  defp bridge_status(%{healthy: false}), do: :error

  defp bridge_status_text(%{healthy: nil, last_scan: nil}), do: "Not configured"

  defp bridge_status_text(%{healthy: nil, last_scan: last_scan}),
    do: "Scan #{relative_time(last_scan)}"

  defp bridge_status_text(%{healthy: true, last_scan: nil}), do: "Healthy"

  defp bridge_status_text(%{healthy: true, last_scan: last_scan}),
    do: "Healthy · Scan #{relative_time(last_scan)}"

  defp bridge_status_text(%{healthy: false}), do: "Unhealthy"
end
