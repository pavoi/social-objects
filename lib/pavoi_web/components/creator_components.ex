defmodule PavoiWeb.CreatorComponents do
  @moduledoc """
  Reusable components for creator CRM features.
  """
  use Phoenix.Component

  import PavoiWeb.CoreComponents
  import PavoiWeb.ViewHelpers

  alias Pavoi.Creators.Creator
  alias Pavoi.Outreach.OutreachLog
  alias Phoenix.LiveView.JS

  use Phoenix.VerifiedRoutes,
    endpoint: PavoiWeb.Endpoint,
    router: PavoiWeb.Router,
    statics: PavoiWeb.static_paths()

  @badge_colors %{
    "bronze" => "creator-badge--bronze",
    "silver" => "creator-badge--silver",
    "gold" => "creator-badge--gold",
    "platinum" => "creator-badge--platinum",
    "ruby" => "creator-badge--ruby",
    "emerald" => "creator-badge--emerald",
    "sapphire" => "creator-badge--sapphire",
    "diamond" => "creator-badge--diamond"
  }

  @doc """
  Renders tag pills for a creator's tags.

  ## Examples

      <.tag_pills tags={@creator.creator_tags} />
  """
  attr :tags, :list, default: []
  attr :max_visible, :integer, default: 3
  attr :in_table, :boolean, default: false

  def tag_pills(assigns) do
    visible_tags = Enum.take(assigns.tags || [], assigns.max_visible)
    remaining_count = max(0, length(assigns.tags || []) - assigns.max_visible)
    assigns = assign(assigns, visible_tags: visible_tags, remaining_count: remaining_count)

    ~H"""
    <%= if @tags && @tags != [] do %>
      <div
        class={["tag-pills", @in_table && "tag-pills--table"]}
        data-total-tags={length(@tags || [])}
      >
        <%= for tag <- @visible_tags do %>
          <%= if is_binary(tag) do %>
            <span class="tag-pill tag-pill--gray" data-tag>{tag}</span>
          <% else %>
            <span class={"tag-pill tag-pill--#{tag.color}"} data-tag>{tag.name}</span>
          <% end %>
        <% end %>
        <%= if @remaining_count > 0 && !@in_table do %>
          <span class="tag-pill tag-pill--more">+{@remaining_count}</span>
        <% end %>
      </div>
    <% end %>
    """
  end

  @doc """
  Renders a clickable tag cell for the creator table.

  Shows existing tags with a click handler to open the tag picker.
  """
  attr :creator, :any, required: true

  def tag_cell(assigns) do
    creator_tags = assigns.creator.creator_tags || []
    assigns = assign(assigns, :creator_tags, creator_tags)

    ~H"""
    <div
      id={"tag-cell-#{@creator.id}"}
      class="tag-cell"
      data-tag-cell-id={@creator.id}
      phx-click="open_tag_picker"
      phx-value-creator-id={@creator.id}
      phx-hook="TagOverflow"
    >
      <%= if @creator_tags == [] do %>
        <span class="tag-cell__placeholder">Add tags</span>
      <% else %>
        <.tag_pills tags={@creator_tags} max_visible={10} in_table={true} />
      <% end %>
    </div>
    """
  end

  @doc """
  Renders the tag picker dropdown.
  """
  attr :creator_id, :any, required: true
  attr :available_tags, :list, default: []
  attr :selected_tag_ids, :list, default: []
  attr :search_query, :string, default: ""
  attr :new_tag_color, :string, default: "gray"

  def tag_picker(assigns) do
    search_query = assigns.search_query || ""

    filtered_tags =
      if search_query == "" do
        assigns.available_tags
      else
        query = String.downcase(search_query)

        Enum.filter(assigns.available_tags, fn tag ->
          String.contains?(String.downcase(tag.name), query)
        end)
      end

    # Sort applied tags to the top
    selected_ids = assigns.selected_tag_ids || []

    filtered_tags =
      Enum.sort_by(filtered_tags, fn tag ->
        if tag.id in selected_ids, do: 0, else: 1
      end)

    # Check if search query exactly matches an existing tag
    exact_match =
      search_query != "" &&
        Enum.any?(assigns.available_tags, fn tag ->
          String.downcase(tag.name) == String.downcase(search_query)
        end)

    # Show quick create when searching and no exact match exists
    show_quick_create =
      search_query != "" && !exact_match && String.length(String.trim(search_query)) > 0

    assigns =
      assigns
      |> assign(:filtered_tags, filtered_tags)
      |> assign(:show_quick_create, show_quick_create)
      |> assign(:search_query, search_query)

    ~H"""
    <div id="tag-picker" class="tag-picker" data-creator-id={@creator_id} phx-hook="ConfirmDelete">
      <div class="tag-picker__search">
        <input
          id="tag-picker-input"
          type="text"
          placeholder="Search or create tag..."
          value={@search_query}
          phx-keyup="search_tags"
          phx-debounce="150"
          maxlength="20"
        />
      </div>

      <%!-- Inline create option when typing a new tag name --%>
      <%= if @show_quick_create do %>
        <div class="tag-picker__quick-create">
          <div class="tag-picker__quick-create-row">
            <div class="tag-picker__quick-colors">
              <%= for color <- ~w(amber blue green red purple gray) do %>
                <button
                  type="button"
                  class={[
                    "tag-picker__quick-color",
                    "color-accent--#{color}",
                    @new_tag_color == color && "tag-picker__quick-color--selected"
                  ]}
                  phx-click="select_new_tag_color"
                  phx-value-color={color}
                  title={String.capitalize(color)}
                />
              <% end %>
            </div>
            <button
              type="button"
              class={["tag-picker__quick-create-btn", "color-accent--#{@new_tag_color}"]}
              phx-click="quick_create_tag"
              phx-value-creator-id={@creator_id}
              phx-value-name={@search_query}
              phx-value-color={@new_tag_color}
            >
              <span>Create "<strong>{@search_query}</strong>"</span>
            </button>
          </div>
        </div>
      <% end %>

      <div class="tag-picker__list">
        <%= if @filtered_tags == [] && !@show_quick_create do %>
          <div class="tag-picker__empty">
            No tags yet. Type to create one.
          </div>
        <% else %>
          <%= for tag <- @filtered_tags do %>
            <div
              class={["tag-picker__item", tag.id in @selected_tag_ids && "tag-picker__item--selected"]}
              phx-click="toggle_tag"
              phx-value-creator-id={@creator_id}
              phx-value-tag-id={tag.id}
            >
              <div class="tag-picker__item-check">
                <%= if tag.id in @selected_tag_ids do %>
                  <.icon name="hero-check" class="size-4" />
                <% end %>
              </div>
              <div class={"tag-picker__item-color color-accent--#{tag.color}"}></div>
              <span class="tag-picker__item-name">{tag.name}</span>
              <%= if tag.id in @selected_tag_ids do %>
                <button
                  type="button"
                  class="tag-picker__item-delete"
                  phx-click="toggle_tag"
                  phx-value-creator-id={@creator_id}
                  phx-value-tag-id={tag.id}
                  title="Remove tag"
                >
                  ×
                </button>
              <% end %>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Renders the tag filter dropdown for the table header.
  """
  attr :available_tags, :list, default: []
  attr :selected_tag_ids, :list, default: []
  attr :open, :boolean, default: false

  def tag_filter(assigns) do
    selected_count = length(assigns.selected_tag_ids)
    assigns = assign(assigns, :selected_count, selected_count)

    ~H"""
    <div class="tag-filter" phx-click-away={@open && "close_tag_filter"}>
      <button
        type="button"
        class={["tag-filter__trigger", @selected_count > 0 && "tag-filter__trigger--active"]}
        phx-click="toggle_tag_filter"
      >
        <.icon name="hero-tag" class="size-4" />
        <span>
          <%= if @selected_count > 0 do %>
            Tags ({@selected_count})
          <% else %>
            Tags
          <% end %>
        </span>
        <%= if @selected_count > 0 do %>
          <span class="tag-filter__clear-x" phx-click="clear_tag_filter" title="Clear filter">×</span>
        <% else %>
          <.icon name="hero-chevron-down" class="size-4" />
        <% end %>
      </button>

      <%= if @open do %>
        <div id="tag-filter-dropdown" class="tag-filter__dropdown" phx-hook="ConfirmDelete">
          <%= if @available_tags == [] do %>
            <div class="tag-filter__empty">No tags available</div>
          <% else %>
            <div class="tag-filter__list">
              <%= for tag <- @available_tags do %>
                <div class="tag-filter__item">
                  <label class="tag-filter__item-label">
                    <input
                      type="checkbox"
                      checked={tag.id in @selected_tag_ids}
                      phx-click="toggle_filter_tag"
                      phx-value-tag-id={tag.id}
                    />
                    <div class={"tag-filter__item-color color-accent--#{tag.color}"}></div>
                    <span class="tag-filter__item-name">{tag.name}</span>
                  </label>
                  <button
                    type="button"
                    class="tag-picker__item-delete"
                    phx-click="delete_tag"
                    phx-value-tag-id={tag.id}
                    title="Delete tag"
                  >
                    ×
                  </button>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a data freshness status indicator.
  Shows last sync times for various data sources with color-coded staleness indicators on hover.
  """
  attr :videos_last_import_at, :any, default: nil
  attr :enrichment_last_sync_at, :any, default: nil

  def data_freshness_panel(assigns) do
    assigns =
      assigns
      |> assign(:videos_status, freshness_status(assigns.videos_last_import_at))
      |> assign(:enrichment_status, freshness_status(assigns.enrichment_last_sync_at))

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
        <%= if has_stale_data?([@videos_status, @enrichment_status]) do %>
          <span class="data-freshness__warning">!</span>
        <% end %>
      </div>

      <div class="data-freshness__panel">
        <div class="data-freshness__header">Data Freshness</div>
        <div class="data-freshness__item">
          <span class={"data-freshness__dot data-freshness__dot--#{@videos_status.level}"} />
          <div class="data-freshness__label">
            <strong>Video/Commission Data</strong>
            <span class="data-freshness__source">CSV Import</span>
          </div>
          <span class="data-freshness__time">{@videos_status.text}</span>
        </div>

        <div class="data-freshness__item">
          <span class={"data-freshness__dot data-freshness__dot--#{@enrichment_status.level}"} />
          <div class="data-freshness__label">
            <strong>Creator Metrics</strong>
            <span class="data-freshness__source">TikTok API</span>
          </div>
          <span class="data-freshness__time">{@enrichment_status.text}</span>
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
  Renders the time filter dropdown for filtering creators by when they were added.
  """
  attr :added_after, :string, default: nil
  attr :added_before, :string, default: nil
  attr :open, :boolean, default: false

  def time_filter(assigns) do
    has_filter = assigns.added_after || assigns.added_before

    label =
      cond do
        assigns.added_after && assigns.added_before ->
          "#{format_short_date(assigns.added_after)} - #{format_short_date(assigns.added_before)}"

        assigns.added_after ->
          "After #{format_short_date(assigns.added_after)}"

        assigns.added_before ->
          "Before #{format_short_date(assigns.added_before)}"

        true ->
          "Date Added"
      end

    assigns = assign(assigns, has_filter: has_filter, label: label)

    ~H"""
    <div class="time-filter" phx-click-away={@open && "close_time_filter"}>
      <button
        type="button"
        class={["time-filter__trigger", @has_filter && "time-filter__trigger--active"]}
        phx-click="toggle_time_filter"
      >
        <.icon name="hero-calendar" class="size-4" />
        <span>{@label}</span>
        <%= if @has_filter do %>
          <span
            class="time-filter__clear-x"
            phx-click="clear_time_filter"
            title="Clear filter"
          >
            ×
          </span>
        <% else %>
          <.icon name="hero-chevron-down" class="size-4" />
        <% end %>
      </button>

      <%= if @open do %>
        <div class="time-filter__dropdown">
          <form phx-submit="apply_time_filter" class="time-filter__form">
            <div class="time-filter__field">
              <label>Added after</label>
              <input type="date" name="after" value={@added_after} />
            </div>
            <div class="time-filter__field">
              <label>Added before</label>
              <input type="date" name="before" value={@added_before} />
            </div>
            <div class="time-filter__actions">
              <button type="button" class="btn btn--ghost btn--sm" phx-click="clear_time_filter">
                Clear
              </button>
              <button type="submit" class="btn btn--primary btn--sm">
                Apply
              </button>
            </div>
          </form>
        </div>
      <% end %>
    </div>
    """
  end

  defp format_short_date(nil), do: ""

  defp format_short_date(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> Calendar.strftime(date, "%b %d")
      {:error, _} -> date_string
    end
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
  Renders a batch tag picker modal content for applying tags to multiple creators.
  """
  attr :available_tags, :list, default: []
  attr :selected_tag_ids, :list, default: []
  attr :creator_count, :integer, default: 0

  def batch_tag_picker(assigns) do
    ~H"""
    <div class="batch-tag-picker">
      <div class="modal__header">
        <h2 class="modal__title">Add Tags to {@creator_count} Creators</h2>
      </div>
      <div class="modal__body">
        <%= if @available_tags == [] do %>
          <div class="batch-tag-picker__empty">
            <p>No tags available.</p>
            <p class="text-secondary text-sm">
              Create tags by clicking on the Tags column in the table.
            </p>
          </div>
        <% else %>
          <p class="text-secondary" style="margin-bottom: var(--space-3);">
            Select tags to add to the selected creators:
          </p>
          <div class="batch-tag-picker__list">
            <%= for tag <- @available_tags do %>
              <label class="batch-tag-picker__item">
                <input
                  type="checkbox"
                  checked={tag.id in @selected_tag_ids}
                  phx-click="toggle_batch_tag"
                  phx-value-tag-id={tag.id}
                />
                <div class={"tag-picker__item-color color-accent--#{tag.color}"}></div>
                <span class="batch-tag-picker__item-name">{tag.name}</span>
              </label>
            <% end %>
          </div>
        <% end %>
      </div>
      <div class="modal__footer">
        <.button variant="outline" phx-click="close_batch_tag_picker">Cancel</.button>
        <.button
          variant="primary"
          phx-click="apply_batch_tags"
          disabled={@selected_tag_ids == [] || @available_tags == []}
        >
          Apply Tags ({length(@selected_tag_ids)})
        </.button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a whitelisted indicator badge.

  ## Examples

      <.whitelisted_badge is_whitelisted={true} />
  """
  attr :is_whitelisted, :boolean, default: false

  def whitelisted_badge(assigns) do
    ~H"""
    <%= if @is_whitelisted do %>
      <span class="whitelisted-badge" title="Whitelisted Creator">
        <.icon name="hero-star-solid" class="size-4" /> Whitelisted
      </span>
    <% end %>
    """
  end

  @doc """
  Renders a colored badge pill for TikTok creator badge level.

  ## Examples

      <.badge_pill level="gold" />
      <.badge_pill level={@creator.tiktok_badge_level} />
  """
  attr :level, :string, default: nil

  def badge_pill(assigns) do
    badge_class = Map.get(@badge_colors, assigns.level, "creator-badge--none")
    assigns = assign(assigns, :badge_class, badge_class)

    ~H"""
    <%= if @level do %>
      <span class={["creator-badge", @badge_class]}>
        {@level}
      </span>
    <% end %>
    """
  end

  @doc """
  Renders a creator avatar with fallback to initials.

  ## Examples

      <.creator_avatar creator={@creator} size="sm" />
      <.creator_avatar creator={@creator} size="lg" />
  """
  attr :creator, :any, required: true
  attr :size, :string, default: "sm"

  def creator_avatar(assigns) do
    initials = get_initials(assigns.creator)
    size_class = "creator-avatar--#{assigns.size}"

    avatar_url =
      case assigns.creator.tiktok_avatar_storage_key do
        nil -> assigns.creator.tiktok_avatar_url
        "" -> assigns.creator.tiktok_avatar_url
        key -> Pavoi.Storage.public_url(key) || assigns.creator.tiktok_avatar_url
      end

    assigns = assign(assigns, initials: initials, size_class: size_class, avatar_url: avatar_url)

    ~H"""
    <%= if @avatar_url do %>
      <img
        src={@avatar_url}
        alt=""
        class={["creator-avatar", @size_class]}
        loading="lazy"
      />
    <% else %>
      <div class={["creator-avatar", "creator-avatar--fallback", @size_class]}>
        {@initials}
      </div>
    <% end %>
    """
  end

  defp get_initials(creator) do
    initials_from_nickname(creator.tiktok_nickname) ||
      initials_from_username(creator.tiktok_username) ||
      initials_from_name(creator.first_name, creator.last_name) ||
      "?"
  end

  defp initials_from_nickname(nil), do: nil
  defp initials_from_nickname(""), do: nil

  defp initials_from_nickname(nickname) do
    nickname
    |> String.split()
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end

  defp initials_from_username(nil), do: nil
  defp initials_from_username(""), do: nil
  defp initials_from_username(username), do: username |> String.slice(0, 2) |> String.upcase()

  defp initials_from_name(nil, _), do: nil
  defp initials_from_name("", _), do: nil

  defp initials_from_name(first, last) do
    first_initial = String.first(first) || ""
    last_initial = if last, do: String.first(last) || "", else: ""
    String.upcase(first_initial <> last_initial)
  end

  @doc """
  Formats a phone number for display.

  ## Examples

      format_phone("+15551234567") # => "(555) 123-4567"
      format_phone("5551234567") # => "(555) 123-4567"
      format_phone(nil) # => "-"
  """
  def format_phone(nil), do: "-"
  def format_phone(""), do: "-"

  def format_phone(phone) do
    # Remove non-digits
    digits = String.replace(phone, ~r/[^\d]/, "")

    case String.length(digits) do
      # 10 digit US number
      10 ->
        "(#{String.slice(digits, 0, 3)}) #{String.slice(digits, 3, 3)}-#{String.slice(digits, 6, 4)}"

      # 11 digit with country code (1 for US)
      11 ->
        if String.starts_with?(digits, "1") do
          rest = String.slice(digits, 1, 10)
          "(#{String.slice(rest, 0, 3)}) #{String.slice(rest, 3, 3)}-#{String.slice(rest, 6, 4)}"
        else
          phone
        end

      # Other formats - return as-is
      _ ->
        phone
    end
  end

  # format_gmv/1 and format_number/1 are imported from PavoiWeb.ViewHelpers

  @doc """
  Returns the creator's display name (full name, or "-" if none).
  """
  def display_name(creator) do
    case Creator.full_name(creator) do
      nil -> "-"
      "" -> "-"
      name -> name
    end
  end

  @doc """
  Capitalizes the status text for display.
  """
  def display_status(nil), do: "Pending"
  def display_status(""), do: "Pending"
  def display_status(status), do: String.capitalize(status)

  @doc """
  Renders the engagement status badge for a creator.
  Shows detailed email engagement status when available.
  """
  attr :creator, :map, required: true

  def engagement_status_badge(assigns) do
    # Determine status based on email_outreach_log if present
    {label, status_type} = get_engagement_status(assigns.creator)

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:status_type, status_type)

    ~H"""
    <span class={["badge", badge_class_for_status(@status_type)]}>
      {@label}
    </span>
    """
  end

  defp get_engagement_status(creator) do
    cond do
      # If they have an email outreach log, use its engagement status
      Map.get(creator, :email_outreach_log) ->
        OutreachLog.engagement_status(creator.email_outreach_log)

      # Skipped creators
      creator.outreach_status == "skipped" ->
        {"Skipped", :skipped}

      # Unsubscribed creators
      creator.outreach_status == "unsubscribed" ->
        {"Unsubscribed", :unsubscribed}

      # Pending or nil (not yet sent)
      creator.outreach_status in [nil, "", "pending", "approved"] ->
        {"Pending", :pending}

      # Fallback for any other status
      true ->
        {display_status(creator.outreach_status), :sent}
    end
  end

  defp badge_class_for_status(:pending), do: "badge--warning"
  defp badge_class_for_status(:sent), do: "badge--info"
  defp badge_class_for_status(:delivered), do: "badge--teal"
  defp badge_class_for_status(:opened), do: "badge--success"
  defp badge_class_for_status(:clicked), do: "badge--success-bright"
  defp badge_class_for_status(:bounced), do: "badge--danger"
  defp badge_class_for_status(:spam), do: "badge--danger"
  defp badge_class_for_status(:unsubscribed), do: "badge--muted"
  defp badge_class_for_status(:skipped), do: "badge--muted"
  defp badge_class_for_status(_), do: "badge--muted"

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
                label="Samples"
                field="samples"
                current={@sort_by}
                dir={@sort_dir}
                on_sort={@on_sort}
                class="text-right"
              />
              <.sort_header
                label="Videos"
                field="videos"
                current={@sort_by}
                dir={@sort_dir}
                on_sort={@on_sort}
                class="text-right"
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
                    <span class="badge badge--success">Yes</span>
                  <% else %>
                    <span class="badge badge--muted">No</span>
                  <% end %>
                </td>
                <td>
                  <span class={[
                    "badge",
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

  def unified_creator_table(assigns) do
    all_selected =
      assigns.selected_ids && MapSet.size(assigns.selected_ids) == assigns.total_count &&
        assigns.total_count > 0

    assigns = assign(assigns, :all_selected, all_selected)

    ~H"""
    <div class="creator-table-wrapper">
      <table
        id="unified-creators-table"
        class="creator-table mode-unified has-checkbox"
        phx-hook="ColumnResize"
        data-table-id="creators-unified"
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
            />
            <%!-- 3. Avatar + Username --%>
            <.sort_header
              label="Creator"
              field="username"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
            />
            <%!-- 4. Email --%>
            <.sort_header
              label="Email"
              field="email"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
            />
            <%!-- 5. Tags --%>
            <th class="col-tags" data-column-id="tags">Tags</th>
            <%!-- 6. Followers --%>
            <.sort_header
              label="Followers"
              field="followers"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
              class="text-right"
            />
            <%!-- 7. Total GMV --%>
            <.sort_header
              label="GMV"
              field="gmv"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
              class="text-right"
            />
            <%!-- 8. Video GMV --%>
            <.sort_header
              label="Video GMV"
              field="video_gmv"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
              class="text-right"
            />
            <%!-- 9. Avg Views --%>
            <.sort_header
              label="Avg Views"
              field="avg_views"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
              class="text-right"
            />
            <%!-- 10. Samples --%>
            <.sort_header
              label="Samples"
              field="samples"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
              class="text-right"
            />
            <%!-- 11. Videos Posted --%>
            <.sort_header
              label="Videos"
              field="videos_posted"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
              class="text-right"
            />
            <%!-- 12. Commission --%>
            <.sort_header
              label="Commission"
              field="commission"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
              class="text-right"
            />
            <%!-- 13. Enriched --%>
            <.sort_header
              label="Enriched"
              field="enriched"
              current={@sort_by}
              dir={@sort_dir}
              on_sort={@on_sort}
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
              <td class="col-checkbox" phx-click="stop_propagation">
                <input
                  type="checkbox"
                  checked={@selected_ids && MapSet.member?(@selected_ids, creator.id)}
                  phx-click="toggle_selection"
                  phx-value-id={creator.id}
                />
              </td>
              <%!-- 2. Status --%>
              <td class="text-center">
                <.engagement_status_badge creator={creator} />
              </td>
              <%!-- 3. Avatar + Username + Nickname --%>
              <td>
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
              <td class="text-secondary">{creator.email || "-"}</td>
              <%!-- 5. Tags --%>
              <td class="col-tags" phx-click="stop_propagation">
                <.tag_cell creator={creator} />
              </td>
              <%!-- 6. Followers --%>
              <td class="text-right">{format_number(creator.follower_count)}</td>
              <%!-- 7. Total GMV --%>
              <td class="text-right">{format_gmv(creator.total_gmv_cents)}</td>
              <%!-- 8. Video GMV --%>
              <td class="text-right">{format_gmv(creator.video_gmv_cents)}</td>
              <%!-- 9. Avg Views --%>
              <td class="text-right">{format_number(creator.avg_video_views)}</td>
              <%!-- 10. Samples --%>
              <td class="text-right">{creator.sample_count || 0}</td>
              <%!-- 11. Videos Posted --%>
              <td class="text-right">{creator.video_count || 0}</td>
              <%!-- 12. Commission --%>
              <td class="text-right">{format_gmv(creator.total_commission_cents)}</td>
              <%!-- 13. Enriched --%>
              <td class="text-secondary text-xs">
                {if creator.last_enriched_at,
                  do: format_relative_time(creator.last_enriched_at),
                  else: "Never"}
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders a sortable table header.
  """
  attr :label, :string, required: true
  attr :field, :string, required: true
  attr :current, :string, default: nil
  attr :dir, :string, default: "asc"
  attr :on_sort, :string, default: nil
  attr :class, :string, default: nil

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
      class={["sortable-header", @class, @is_active && "sortable-header--active"]}
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
