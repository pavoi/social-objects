defmodule SocialObjectsWeb.VideoComponents do
  @moduledoc """
  Reusable components for video performance display.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias SocialObjectsWeb.BrandRoutes

  import SocialObjectsWeb.CoreComponents
  import SocialObjectsWeb.FilterComponents
  import SocialObjectsWeb.ViewHelpers

  @doc """
  Renders a video card for the grid display.

  Displays thumbnail with play overlay, duration badge, creator info, title, and metrics.
  """
  attr :video, :any, required: true
  attr :current_brand, :any, required: true
  attr :current_host, :string, required: true

  def video_card(assigns) do
    ~H"""
    <div
      id={"video-card-#{@video.id}"}
      class="video-card"
      data-video-id={@video.id}
    >
      <div class="video-card__thumbnail-container">
        <.video_thumbnail video={@video} />
        <%= if @video.duration do %>
          <span class="video-card__duration">{format_video_duration(@video.duration)}</span>
        <% end %>
        <div class="video-card__play-overlay">
          <svg class="video-card__play-icon" viewBox="0 0 24 24" fill="currentColor">
            <path d="M8 5v14l11-7z" />
          </svg>
        </div>
      </div>

      <div class="video-card__content">
        <div class="video-card__creator">
          <.creator_avatar_mini creator={@video.creator} />
          <a
            href={creator_modal_url(@current_brand, @current_host, @video.creator.id)}
            target="_blank"
            rel="noopener noreferrer"
            class="video-card__username video-card__username--link"
          >
            @{@video.creator.tiktok_username}
          </a>
        </div>

        <h3 class="video-card__title" title={@video.title}>
          {truncate_title(@video.title)}
        </h3>

        <div class="video-card__metrics">
          <div class="video-card__metric video-card__metric--gmv">
            <span class="video-card__metric-value">{format_gmv(@video.gmv_cents)}</span>
            <span class="video-card__metric-label">GMV</span>
          </div>
          <div class="video-card__metric">
            <span class="video-card__metric-value">{format_gmv_or_dash(@video.gpm_cents)}</span>
            <span class="video-card__metric-label">GPM</span>
          </div>
          <div class="video-card__metric">
            <span class="video-card__metric-value">{format_sales(@video.items_sold)}</span>
            <span class="video-card__metric-label">Sales</span>
          </div>
          <div class="video-card__metric">
            <span class="video-card__metric-value">{format_views(@video.impressions)}</span>
            <span class="video-card__metric-label">Views</span>
          </div>
          <div class="video-card__metric">
            <span class="video-card__metric-value">{format_ctr(@video.ctr)}</span>
            <span class="video-card__metric-label">CTR</span>
          </div>
        </div>

        <div class="video-card__footer">
          <span class="video-card__date">{format_video_date(@video.posted_at)}</span>
          <a
            href={video_url(@video)}
            target="_blank"
            rel="noopener noreferrer"
            class="video-card__tiktok-link"
            title="Watch on TikTok"
          >
            <svg viewBox="0 0 24 24" fill="currentColor" class="video-card__tiktok-icon">
              <path d="M19.59 6.69a4.83 4.83 0 0 1-3.77-4.25V2h-3.45v13.67a2.89 2.89 0 0 1-5.2 1.74 2.89 2.89 0 0 1 2.31-4.64 2.93 2.93 0 0 1 .88.13V9.4a6.84 6.84 0 0 0-1-.05A6.33 6.33 0 0 0 5 20.1a6.34 6.34 0 0 0 10.86-4.43v-7a8.16 8.16 0 0 0 4.77 1.52v-3.4a4.85 4.85 0 0 1-1-.1z" />
            </svg>
            <span>TikTok</span>
          </a>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders video thumbnail with actual image or placeholder fallback.
  Uses storage key if available, falling back to thumbnail_url.
  """
  attr :video, :any, required: true

  def video_thumbnail(assigns) do
    thumbnail_url =
      case assigns.video do
        %{thumbnail_storage_key: key} when is_binary(key) and key != "" ->
          SocialObjects.Storage.public_url(key) || assigns.video.thumbnail_url

        %{thumbnail_url: url} when is_binary(url) and url != "" ->
          url

        _ ->
          nil
      end

    assigns = assign(assigns, :thumbnail_url, thumbnail_url)

    ~H"""
    <div class="video-thumbnail">
      <%= if @thumbnail_url do %>
        <img
          src={@thumbnail_url}
          alt=""
          class="video-thumbnail__image"
          loading="lazy"
        />
      <% else %>
        <div class="video-thumbnail__placeholder">
          <svg
            class="video-thumbnail__icon"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <path d="m22 8-6 4 6 4V8Z" /><rect x="2" y="6" width="14" height="12" rx="2" />
          </svg>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a mini creator avatar for video cards.
  Uses local storage URL if available, falling back to TikTok CDN URL.
  """
  attr :creator, :any, required: true

  def creator_avatar_mini(assigns) do
    avatar_url =
      case assigns.creator do
        nil ->
          nil

        creator ->
          case creator.tiktok_avatar_storage_key do
            nil -> creator.tiktok_avatar_url
            "" -> creator.tiktok_avatar_url
            key -> SocialObjects.Storage.public_url(key) || creator.tiktok_avatar_url
          end
      end

    initials = get_creator_initials(assigns.creator)
    assigns = assign(assigns, avatar_url: avatar_url, initials: initials)

    ~H"""
    <%= if @avatar_url do %>
      <img src={@avatar_url} alt="" class="creator-avatar-mini" loading="lazy" />
    <% else %>
      <div class="creator-avatar-mini creator-avatar-mini--placeholder">
        {@initials}
      </div>
    <% end %>
    """
  end

  defp get_creator_initials(nil), do: "?"

  defp get_creator_initials(creator) do
    cond do
      creator.tiktok_nickname && creator.tiktok_nickname != "" ->
        creator.tiktok_nickname |> String.first() |> String.upcase()

      creator.tiktok_username && creator.tiktok_username != "" ->
        creator.tiktok_username |> String.first() |> String.upcase()

      true ->
        "?"
    end
  end

  @doc """
  Renders the video grid container.
  """
  attr :videos, :list, required: true
  attr :has_more, :boolean, default: false
  attr :loading, :boolean, default: false
  attr :is_empty, :boolean, default: false
  attr :current_brand, :any, required: true
  attr :current_host, :string, required: true

  def video_grid(assigns) do
    ~H"""
    <div class="video-grid" id="video-grid-container" phx-hook="VideoGridHover">
      <%= if @is_empty do %>
        <div class="video-grid__empty">
          <svg
            class="video-grid__empty-icon"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
          >
            <path d="m22 8-6 4 6 4V8Z" /><rect x="2" y="6" width="14" height="12" rx="2" />
          </svg>
          <p class="video-grid__empty-title">No videos found</p>
          <p class="video-grid__empty-description">
            Try adjusting your search or filters
          </p>
        </div>
      <% else %>
        <div
          id="videos-grid"
          class="video-grid__grid"
          phx-hook="InfiniteScroll"
          data-load-event="load_more"
          data-has-more={to_string(@has_more)}
          data-loading={to_string(@loading)}
          data-scroll-scope="viewport"
          phx-update="replace"
        >
          <%= for video <- @videos do %>
            <.video_card video={video} current_brand={@current_brand} current_host={@current_host} />
          <% end %>
        </div>

        <%= if @loading do %>
          <div class="video-grid__loader">
            <div class="spinner"></div>
            <span>Loading more videos...</span>
          </div>
        <% else %>
          <%= if @has_more do %>
            <div class="video-grid__loader">
              <.button type="button" variant="outline" size="sm" phx-click="load_more">
                Load More Videos
              </.button>
            </div>
          <% end %>
        <% end %>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders the filter controls for the videos page.
  """
  attr :search_query, :string, default: ""
  attr :sort_by, :string, default: "gmv"
  attr :sort_dir, :string, default: "desc"
  attr :creators, :list, default: []
  attr :selected_creator_id, :any, default: nil
  attr :total, :integer, default: 0
  attr :time_preset, :string, default: "all"
  attr :min_gmv, :any, default: nil
  attr :time_filter_open, :boolean, default: false
  attr :min_gmv_filter_open, :boolean, default: false
  attr :creator_filter_open, :boolean, default: false
  attr :sort_filter_open, :boolean, default: false

  def video_filters(assigns) do
    ~H"""
    <div class="video-filters">
      <div class="video-filters__left">
        <div class="video-filters__search-wrapper">
          <.search_input
            value={@search_query}
            on_change="search"
            placeholder="Search by title, creator, or hashtag..."
            debounce={400}
          />
          <span class="videos-count">{format_number(@total)} videos</span>
        </div>

        <%= if length(@creators) > 0 do %>
          <.hover_dropdown
            id="creator-filter"
            options={
              [{"", "All Creators"}] ++ Enum.map(@creators, &{&1.id, "@#{&1.tiktok_username}"})
            }
            current_value={@selected_creator_id}
            change_event="filter_creator"
            toggle_event="toggle_creator_filter"
            open={@creator_filter_open}
            searchable={true}
            search_placeholder="Search creators..."
            empty_label="No creators found"
          />
        <% end %>
      </div>

      <div class="video-filters__right">
        <div class="video-filters__presets">
          <%!-- Min GMV Filter (only shown when not sorting by GMV) --%>
          <%= if @sort_by != "gmv" do %>
            <div class={["preset-filter", "preset-filter--min-gmv", @min_gmv_filter_open && "is-open"]}>
              <button
                type="button"
                class="preset-filter__trigger"
                phx-click="toggle_min_gmv_filter"
                aria-label="Toggle minimum GMV filter"
                aria-expanded={@min_gmv_filter_open}
              >
                <svg
                  class="preset-filter__trigger-icon"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2"
                >
                  <line x1="12" y1="1" x2="12" y2="23" /><path d="M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" />
                </svg>
                <%= if @min_gmv do %>
                  <span class="preset-filter__trigger-value">{format_min_gmv_short(@min_gmv)}</span>
                <% end %>
              </button>
              <div class="preset-filter__content">
                <span class="preset-filter__label">Min GMV</span>
                <div class="preset-filter__buttons">
                  <button
                    type="button"
                    class={"preset-filter__btn #{if @min_gmv == 50_000, do: "preset-filter__btn--active"}"}
                    phx-click="set_min_gmv"
                    phx-value-amount="50000"
                  >
                    $500
                  </button>
                  <button
                    type="button"
                    class={"preset-filter__btn #{if @min_gmv == 100_000, do: "preset-filter__btn--active"}"}
                    phx-click="set_min_gmv"
                    phx-value-amount="100000"
                  >
                    $1K
                  </button>
                  <button
                    type="button"
                    class={"preset-filter__btn #{if @min_gmv == 500_000, do: "preset-filter__btn--active"}"}
                    phx-click="set_min_gmv"
                    phx-value-amount="500000"
                  >
                    $5K
                  </button>
                </div>
              </div>
            </div>
          <% end %>

          <%!-- Time Period Filter --%>
          <div class={["preset-filter", "preset-filter--time", @time_filter_open && "is-open"]}>
            <button
              type="button"
              class="preset-filter__trigger"
              phx-click="toggle_time_filter"
              aria-label="Toggle time period filter"
              aria-expanded={@time_filter_open}
            >
              <svg
                class="preset-filter__trigger-icon"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
              >
                <circle cx="12" cy="12" r="10" /><polyline points="12,6 12,12 16,14" />
              </svg>
              <%= if @time_preset != "all" do %>
                <span class="preset-filter__trigger-value">L{@time_preset}d</span>
              <% end %>
            </button>
            <div class="preset-filter__content">
              <span class="preset-filter__label">Period</span>
              <div class="preset-filter__buttons">
                <button
                  type="button"
                  class={"preset-filter__btn #{if @time_preset == "all", do: "preset-filter__btn--active"}"}
                  phx-click="set_time_preset"
                  phx-value-preset="all"
                >
                  All Time
                </button>
                <button
                  type="button"
                  class={"preset-filter__btn #{if @time_preset == "90", do: "preset-filter__btn--active"}"}
                  phx-click="set_time_preset"
                  phx-value-preset="90"
                >
                  L90d
                </button>
                <button
                  type="button"
                  class={"preset-filter__btn #{if @time_preset == "30", do: "preset-filter__btn--active"}"}
                  phx-click="set_time_preset"
                  phx-value-preset="30"
                >
                  L30d
                </button>
              </div>
            </div>
          </div>
        </div>

        <span class="video-filters__sort-label">Sort by:</span>

        <.hover_dropdown
          id="sort-filter"
          options={[
            {"gmv_desc", "GMV"},
            {"gpm_desc", "GPM"},
            {"views_desc", "Views"},
            {"ctr_desc", "CTR"},
            {"items_sold_desc", "Items Sold"},
            {"posted_at_desc", "Newest First"},
            {"posted_at_asc", "Oldest First"}
          ]}
          current_value={"#{@sort_by}_#{@sort_dir}"}
          change_event="sort_videos"
          toggle_event="toggle_sort_filter"
          open={@sort_filter_open}
        />
      </div>
    </div>
    """
  end

  @doc """
  Renders a hover player overlay centered in viewport.
  Minimal player without info (already shown in card).
  """
  attr :video, :any, default: nil

  def video_hover_player(assigns) do
    ~H"""
    <%= if @video do %>
      <div
        class="video-hover-player video-hover-player--hidden"
        id="video-hover-player"
        phx-mounted={show_video_player()}
      >
        <div class="video-hover-player__backdrop"></div>
        <div class="video-hover-player__wrapper">
          <button type="button" class="video-hover-player__close" aria-label="Close video">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <line x1="18" y1="6" x2="6" y2="18" /><line x1="6" y1="6" x2="18" y2="18" />
            </svg>
          </button>
          <div
            class="video-hover-player__container"
            id="video-hover-player-container"
            phx-hook="TikTokEmbed"
            data-video-id={@video.tiktok_video_id}
            data-video-url={video_url(@video)}
          >
            <div id="tiktok-embed" phx-update="ignore"></div>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  defp show_video_player(js \\ %JS{}) do
    JS.remove_class(js, "video-hover-player--hidden", to: "#video-hover-player")
  end

  # Helper functions

  defp format_video_duration(nil), do: ""

  defp format_video_duration(seconds) when is_integer(seconds) do
    minutes = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{minutes}:#{String.pad_leading(Integer.to_string(secs), 2, "0")}"
  end

  defp format_views(nil), do: "-"
  defp format_views(0), do: "0"

  defp format_views(num) when num >= 1_000_000 do
    "#{Float.round(num / 1_000_000, 1)}M"
  end

  defp format_views(num) when num >= 1_000 do
    "#{Float.round(num / 1_000, 1)}K"
  end

  defp format_views(num), do: Integer.to_string(num)

  defp format_sales(nil), do: "-"
  defp format_sales(0), do: "0"

  defp format_sales(num) when num >= 1_000_000 do
    "#{Float.round(num / 1_000_000, 1)}M"
  end

  defp format_sales(num) when num >= 1_000 do
    "#{Float.round(num / 1_000, 1)}K"
  end

  defp format_sales(num), do: Integer.to_string(num)

  defp format_ctr(nil), do: "-"

  defp format_ctr(ctr) when is_struct(ctr, Decimal) do
    "#{Decimal.round(ctr, 2)}%"
  end

  defp format_ctr(ctr) when is_float(ctr) do
    "#{Float.round(ctr, 2)}%"
  end

  defp format_ctr(_), do: "-"

  defp format_video_date(nil), do: "-"

  defp format_video_date(%DateTime{} = dt) do
    today = Date.utc_today()
    date = DateTime.to_date(dt)

    cond do
      date == today -> "Today"
      date == Date.add(today, -1) -> "Yesterday"
      Date.diff(today, date) < 7 -> Calendar.strftime(dt, "%A")
      true -> Calendar.strftime(dt, "%b %d, %Y")
    end
  end

  defp truncate_title(nil), do: "Untitled"
  defp truncate_title(""), do: "Untitled"

  defp truncate_title(title) do
    if String.length(title) > 50 do
      String.slice(title, 0, 50) <> "..."
    else
      title
    end
  end

  defp video_url(video) do
    if video.video_url && video.video_url != "" do
      video.video_url
    else
      username = video.creator && video.creator.tiktok_username
      "https://www.tiktok.com/@#{username || "unknown"}/video/#{video.tiktok_video_id}"
    end
  end

  defp creator_modal_url(brand, host, creator_id) do
    BrandRoutes.brand_path(brand, "/creators?c=#{creator_id}", host)
  end

  defp format_min_gmv_short(50_000), do: "$500+"
  defp format_min_gmv_short(100_000), do: "$1K+"
  defp format_min_gmv_short(500_000), do: "$5K+"
  defp format_min_gmv_short(_), do: ""
end
