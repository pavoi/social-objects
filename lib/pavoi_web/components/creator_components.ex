defmodule PavoiWeb.CreatorComponents do
  @moduledoc """
  Reusable components for creator CRM features.
  """
  use Phoenix.Component

  import PavoiWeb.CoreComponents
  import PavoiWeb.ViewHelpers

  alias Pavoi.Creators.Creator
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
  Renders tag pills for a creator's tags array.

  ## Examples

      <.tag_pills tags={["vip", "responsive"]} />
  """
  attr :tags, :list, default: []

  def tag_pills(assigns) do
    ~H"""
    <%= if @tags && @tags != [] do %>
      <div class="tag-pills">
        <%= for tag <- @tags do %>
          <span class="tag-pill">{tag}</span>
        <% end %>
      </div>
    <% end %>
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

  @doc """
  Formats cents as currency.

  ## Examples

      format_gmv(123456) # => "$1,235"
      format_gmv(nil) # => "$0"
  """
  def format_gmv(nil), do: "$0"
  def format_gmv(0), do: "$0"

  def format_gmv(cents) when is_integer(cents) do
    dollars = div(cents, 100)
    "$#{format_number(dollars)}"
  end

  # format_number/1 is now imported from PavoiWeb.ViewHelpers

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
    # Add 'has-checkbox' class when in outreach pending mode
    has_checkbox = assigns.mode == "outreach" && assigns.status == "pending"

    all_selected =
      has_checkbox && MapSet.size(assigns.selected_ids) == assigns.total_count &&
        assigns.total_count > 0

    assigns =
      assigns
      |> assign(:has_checkbox, has_checkbox)
      |> assign(:all_selected, all_selected)

    ~H"""
    <div class="creator-table-wrapper">
      <table class={["creator-table", @has_checkbox && "has-checkbox"]}>
        <thead>
          <tr>
            <%= if @mode == "outreach" and @status == "pending" do %>
              <th class="col-checkbox">
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
            <th>Name</th>
            <th>Email</th>
            <th>Phone</th>
            <%= if @mode == "outreach" do %>
              <th>SMS Consent</th>
              <th>Status</th>
              <th>Added</th>
              <%= if @status == "sent" do %>
                <th>Sent</th>
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
                @mode == "outreach" && @selected_ids && MapSet.member?(@selected_ids, creator.id) &&
                  "row--selected"
              ]}
            >
              <%= if @mode == "outreach" and @status == "pending" do %>
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
                    creator.outreach_status == "skipped" && "badge--muted"
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
    <th class={["sortable-header", @class, @is_active && "sortable-header--active"]}>
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
  """
  attr :creator, :any, default: nil
  attr :active_tab, :string, default: "contact"
  attr :editing_contact, :boolean, default: false
  attr :contact_form, :any, default: nil

  def creator_detail_modal(assigns) do
    ~H"""
    <%= if @creator do %>
      <.modal
        id="creator-detail-modal"
        show={true}
        on_cancel={JS.push("close_creator_modal")}
        modal_class="modal__box--wide"
      >
        <div class="modal__header">
          <div class="creator-modal-header">
            <div class="creator-modal-header__title">
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
            </div>
            <div class="creator-modal-header__badges">
              <.whitelisted_badge is_whitelisted={@creator.is_whitelisted} />
              <.badge_pill level={@creator.tiktok_badge_level} />
              <.tag_pills tags={@creator.tags} />
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
              <span class="creator-modal-stat__label">GMV</span>
              <span class="creator-modal-stat__value">{format_gmv(@creator.total_gmv_cents)}</span>
            </div>
            <div class="creator-modal-stat">
              <span class="creator-modal-stat__label">Videos</span>
              <span class="creator-modal-stat__value">{length(@creator.creator_videos)}</span>
            </div>
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
              Samples ({length(@creator.creator_samples)})
            </button>
            <button
              type="button"
              class={["tab", @active_tab == "videos" && "tab--active"]}
              phx-click="change_tab"
              phx-value-tab="videos"
            >
              Videos ({length(@creator.creator_videos)})
            </button>
            <button
              type="button"
              class={["tab", @active_tab == "performance" && "tab--active"]}
              phx-click="change_tab"
              phx-value-tab="performance"
            >
              Performance ({length(@creator.performance_snapshots)})
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
                <.samples_table samples={@creator.creator_samples} />
              <% "videos" -> %>
                <.videos_table videos={@creator.creator_videos} username={@creator.tiktok_username} />
              <% "performance" -> %>
                <.performance_table snapshots={@creator.performance_snapshots} />
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
