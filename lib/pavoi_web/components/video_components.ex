defmodule PavoiWeb.VideoComponents do
  @moduledoc """
  Reusable components for video performance display.
  """
  use Phoenix.Component

  import PavoiWeb.CoreComponents
  import PavoiWeb.ViewHelpers

  @doc """
  Renders a video card for the grid display.

  Displays thumbnail with play overlay, duration badge, creator info, title, and metrics.
  """
  attr :video, :any, required: true
  attr :on_click, :string, default: nil

  def video_card(assigns) do
    ~H"""
    <div
      class="video-card"
      phx-click={@on_click}
      phx-value-id={@video.id}
      role="button"
      tabindex="0"
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
          <span class="video-card__username">@{@video.creator.tiktok_username}</span>
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
            <span class="video-card__metric-value">{format_gpm(@video.gpm_cents)}</span>
            <span class="video-card__metric-label">GPM</span>
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
          <%= if @video.items_sold && @video.items_sold > 0 do %>
            <span class="video-card__items-sold">{@video.items_sold} sold</span>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders video thumbnail with TikTok video placeholder.
  """
  attr :video, :any, required: true

  def video_thumbnail(assigns) do
    ~H"""
    <div class="video-thumbnail">
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
            key -> Pavoi.Storage.public_url(key) || creator.tiktok_avatar_url
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
  attr :on_card_click, :string, default: nil
  attr :has_more, :boolean, default: false
  attr :loading, :boolean, default: false
  attr :is_empty, :boolean, default: false

  def video_grid(assigns) do
    ~H"""
    <div class="video-grid">
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
          phx-viewport-bottom={@has_more && !@loading && "load_more"}
        >
          <%= for video <- @videos do %>
            <.video_card video={video} on_click={@on_card_click} />
          <% end %>
        </div>

        <%= if @loading do %>
          <div class="video-grid__loader">
            <div class="spinner"></div>
            <span>Loading more videos...</span>
          </div>
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

  def video_filters(assigns) do
    ~H"""
    <div class="video-filters">
      <div class="video-filters__left">
        <div class="video-filters__search">
          <.search_input
            value={@search_query}
            on_change="search"
            placeholder="Search by title, creator, or hashtag..."
          />
        </div>

        <%= if length(@creators) > 0 do %>
          <form phx-change="filter_creator" class="video-filters__creator">
            <select name="creator_id" class="filter-select">
              <option value="">All Creators</option>
              <%= for creator <- @creators do %>
                <option value={creator.id} selected={@selected_creator_id == creator.id}>
                  @{creator.tiktok_username}
                </option>
              <% end %>
            </select>
          </form>
        <% end %>
      </div>

      <div class="video-filters__right">
        <form phx-change="sort_videos" class="video-filters__sort">
          <select name="sort" class="filter-select">
            <option value="gmv_desc" selected={@sort_by == "gmv" && @sort_dir == "desc"}>
              GMV: High to Low
            </option>
            <option value="gmv_asc" selected={@sort_by == "gmv" && @sort_dir == "asc"}>
              GMV: Low to High
            </option>
            <option value="gpm_desc" selected={@sort_by == "gpm" && @sort_dir == "desc"}>
              GPM: High to Low
            </option>
            <option value="views_desc" selected={@sort_by == "views" && @sort_dir == "desc"}>
              Views: High to Low
            </option>
            <option value="ctr_desc" selected={@sort_by == "ctr" && @sort_dir == "desc"}>
              CTR: High to Low
            </option>
            <option value="items_sold_desc" selected={@sort_by == "items_sold" && @sort_dir == "desc"}>
              Items Sold: High to Low
            </option>
            <option value="posted_at_desc" selected={@sort_by == "posted_at" && @sort_dir == "desc"}>
              Newest First
            </option>
            <option value="posted_at_asc" selected={@sort_by == "posted_at" && @sort_dir == "asc"}>
              Oldest First
            </option>
          </select>
        </form>

        <button
          type="button"
          class="video-filters__sort-toggle"
          phx-click="toggle_sort_dir"
          title={"Sort #{if @sort_dir == "desc", do: "ascending", else: "descending"}"}
        >
          <svg
            class={["size-5", @sort_dir == "asc" && "rotate-180"]}
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
          >
            <polyline points="6 9 12 15 18 9" />
          </svg>
        </button>
      </div>
    </div>
    """
  end

  # Helper functions

  defp format_video_duration(nil), do: ""

  defp format_video_duration(seconds) when is_integer(seconds) do
    minutes = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{minutes}:#{String.pad_leading(Integer.to_string(secs), 2, "0")}"
  end

  defp format_gpm(nil), do: "$0"

  defp format_gpm(cents) when is_integer(cents) do
    dollars = cents / 100

    if dollars >= 1000 do
      "$#{Float.round(dollars / 1000, 1)}k"
    else
      "$#{trunc(dollars)}"
    end
  end

  defp format_views(nil), do: "0"
  defp format_views(0), do: "0"

  defp format_views(num) when num >= 1_000_000 do
    "#{Float.round(num / 1_000_000, 1)}M"
  end

  defp format_views(num) when num >= 1_000 do
    "#{Float.round(num / 1_000, 1)}K"
  end

  defp format_views(num), do: Integer.to_string(num)

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
end
