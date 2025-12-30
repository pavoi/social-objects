defmodule PavoiWeb.CreatorComponents do
  @moduledoc """
  Display components and helpers for creator CRM.

  For tag management, see `PavoiWeb.CreatorTagComponents`.
  For tables and modals, see `PavoiWeb.CreatorTableComponents`.
  """
  use Phoenix.Component

  import PavoiWeb.CoreComponents
  import PavoiWeb.ViewHelpers

  alias Pavoi.Creators.Creator
  alias Pavoi.Outreach.OutreachLog

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
  Displays a metric with its delta and data quality indicator.

  Shows the current value with an optional delta below it.
  When data is incomplete, shows an asterisk with a tooltip.

  ## Examples

      <.metric_with_delta
        current={creator.total_gmv_cents}
        delta={creator.snapshot_delta.gmv_delta}
        start_date={creator.snapshot_delta.start_date}
        has_complete_data={creator.snapshot_delta.has_complete_data}
        format={:gmv}
      />
  """
  attr :current, :any, required: true
  attr :delta, :any, default: nil
  attr :start_date, :any, default: nil
  attr :has_complete_data, :boolean, default: false
  attr :format, :atom, default: :number

  def metric_with_delta(assigns) do
    ~H"""
    <div class="metric-with-delta">
      <span class="metric-current">
        <%= case @format do %>
          <% :gmv -> %>
            {format_gmv(@current)}
          <% :number -> %>
            {format_number(@current)}
        <% end %>
      </span>
      <%= cond do %>
        <% @delta && @has_complete_data -> %>
          <%!-- Full data available - show delta normally --%>
          <span class={["metric-delta", delta_class(@delta)]}>
            {format_delta(@delta, @format)}
          </span>
        <% @delta -> %>
          <%!-- Partial data - show delta with date qualifier --%>
          <span class={["metric-delta", delta_class(@delta)]}>
            {format_delta(@delta, @format)}
            <span class="metric-delta-qualifier">
              since {Calendar.strftime(@start_date, "%b %d")}
            </span>
          </span>
        <% true -> %>
          <%!-- No snapshot data at all --%>
          <span class="metric-delta metric-delta--no-data">
            no history
          </span>
      <% end %>
    </div>
    """
  end

  defp delta_class(delta) when is_integer(delta) and delta > 0, do: "delta-positive"
  defp delta_class(delta) when is_integer(delta) and delta < 0, do: "delta-negative"
  defp delta_class(_), do: "delta-neutral"

  defp format_delta(delta, :gmv) when is_integer(delta) and delta > 0,
    do: "+#{format_gmv(delta)}"

  defp format_delta(delta, :gmv) when is_integer(delta) and delta < 0,
    do: format_gmv(delta)

  defp format_delta(_delta, :gmv), do: "$0"

  defp format_delta(delta, :number) when is_integer(delta) and delta > 0,
    do: "+#{format_number(delta)}"

  defp format_delta(delta, :number) when is_integer(delta) and delta < 0,
    do: format_number(delta)

  defp format_delta(_delta, :number), do: "0"

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
    <span class={["badge badge--soft", badge_class_for_status(@status_type)]}>
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
end
