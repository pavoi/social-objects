defmodule SocialObjectsWeb.FilterComponents do
  @moduledoc """
  Reusable filter dropdown components with unified styling.

  These components provide a consistent dropdown filter experience across all pages,
  matching the style used in the Creators page.
  """
  use Phoenix.Component

  @doc """
  Renders a hover-triggered dropdown filter matching the Creators page style.

  Desktop: Reveals dropdown on hover via CSS.
  All devices: Supports click-toggle fallback via shared JS hook.

  ## Attributes
  - `options` - List of {value, label} tuples for the dropdown options
  - `current_value` - The currently selected value (string or nil)
  - `open` - Whether the dropdown is open (optional server-controlled open state)
  - `open_on_hover` - Whether desktop opens on hover (`true`) or click only (`false`)
  - `change_event` - Event name when an option is selected (receives "value" param)
  - `toggle_event` - Event name for server-controlled click toggle (optional)
  - `clear_event` - Event name when clear button clicked (optional, shows X when active)
  - `searchable` - Whether to show a client-side search input for options
  - `search_placeholder` - Placeholder text for searchable dropdowns
  - `empty_label` - Empty state text when no options match a search
  - `id` - Unique ID for the component (required for phx-click-away)

  ## Example

      <.hover_dropdown
        id="creator-filter"
        options={[{"", "All Creators"} | Enum.map(@creators, &{&1.id, "@" <> &1.username})]}
        current_value={@selected_creator_id}
        change_event="filter_creator"
        toggle_event="toggle_creator_filter"
        open={@creator_filter_open}
      />
  """
  attr :id, :string, required: true
  attr :options, :list, required: true
  attr :current_value, :any, default: nil
  attr :trigger_label, :string, default: nil
  attr :open, :boolean, default: false
  attr :open_on_hover, :boolean, default: true
  attr :change_event, :string, required: true
  attr :toggle_event, :string, default: nil
  attr :clear_event, :string, default: nil
  attr :searchable, :boolean, default: false
  attr :search_placeholder, :string, default: "Search..."
  attr :empty_label, :string, default: "No results"
  attr :descriptions, :map, default: %{}
  attr :menu_class, :string, default: nil

  def hover_dropdown(assigns) do
    # Find the label for the current value
    current_label =
      assigns.trigger_label ||
        Enum.find_value(assigns.options, fn {value, label} ->
          if to_string(value) == to_string(assigns.current_value), do: label
        end) || elem(List.first(assigns.options), 1)

    # Determine if filter is active (not first option)
    first_value = assigns.options |> List.first() |> elem(0)

    is_active =
      assigns.current_value != nil &&
        assigns.current_value != "" &&
        to_string(assigns.current_value) != to_string(first_value)

    assigns =
      assigns
      |> assign(:current_label, current_label)
      |> assign(:is_active, is_active)

    ~H"""
    <div
      class={[
        "hover-dropdown",
        @open && "is-open",
        @open_on_hover && "hover-dropdown--hover-open",
        !@open_on_hover && "hover-dropdown--click-open"
      ]}
      id={@id}
      phx-hook="HoverDropdown"
    >
      <button
        type="button"
        class={["hover-dropdown__trigger", @is_active && "hover-dropdown__trigger--active"]}
        phx-click={@toggle_event}
      >
        <span class="hover-dropdown__label">{@current_label}</span>
        <%= if @is_active && @clear_event do %>
          <span
            class="hover-dropdown__clear"
            phx-click={@clear_event}
            title="Clear filter"
          >
            ×
          </span>
        <% else %>
          <svg
            class="hover-dropdown__chevron"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <path d="m6 9 6 6 6-6" />
          </svg>
        <% end %>
      </button>

      <div class={["hover-dropdown__menu", @menu_class]}>
        <%= if @searchable do %>
          <div class="hover-dropdown__search">
            <input
              type="text"
              class="input input--sm hover-dropdown__search-input"
              placeholder={@search_placeholder}
              data-hover-dropdown-search
              aria-label={@search_placeholder}
            />
          </div>
        <% end %>

        <div class="hover-dropdown__list">
          <%= for {opt_value, opt_label} <- @options do %>
            <button
              type="button"
              class={[
                "hover-dropdown__item",
                to_string(@current_value) == to_string(opt_value) && "hover-dropdown__item--selected",
                @descriptions != %{} && "hover-dropdown__item--with-description"
              ]}
              phx-click={@change_event}
              phx-value-selection={to_string(opt_value)}
              data-hover-dropdown-option
              data-label={String.downcase(to_string(opt_label))}
            >
              <span class="hover-dropdown__item-label">{opt_label}</span>
              <%= if desc = Map.get(@descriptions, to_string(opt_value)) do %>
                <span class="hover-dropdown__item-description">{desc}</span>
              <% end %>
            </button>
          <% end %>
        </div>

        <%= if @searchable do %>
          <div class="hover-dropdown__empty" data-hover-dropdown-empty hidden>
            {@empty_label}
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Renders a generic filter dropdown with hover behavior.

  ## Attributes
  - `label` - The text displayed on the trigger button
  - `options` - List of {value, label} tuples for the dropdown options
  - `current_value` - The currently selected value
  - `open` - Whether the dropdown is open
  - `event_prefix` - Prefix for event names (e.g., "streams_status" results in "toggle_streams_status", "change_streams_status", "close_streams_status")
  """
  attr :label, :string, required: true
  attr :options, :list, required: true
  attr :current_value, :string, default: ""
  attr :open, :boolean, default: false
  attr :event_prefix, :string, required: true

  def filter_dropdown(assigns) do
    # Determine if the filter is active (not on default/first option)
    first_option_value = List.first(assigns.options) |> elem(0)
    is_active = assigns.current_value != "" && assigns.current_value != first_option_value

    assigns = assign(assigns, :is_active, is_active)

    ~H"""
    <div class="filter-dropdown">
      <button
        type="button"
        class={["filter-dropdown__trigger", @is_active && "filter-dropdown__trigger--active"]}
        phx-click={"toggle_#{@event_prefix}"}
      >
        <span>{@label}</span>
        <%= if @is_active do %>
          <button
            type="button"
            class="filter-dropdown__clear-x"
            phx-click={"clear_#{@event_prefix}"}
            title="Clear filter"
          >
            ×
          </button>
        <% else %>
          <svg
            class="size-4"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <path d="m19.5 8.25-7.5 7.5-7.5-7.5" />
          </svg>
        <% end %>
      </button>

      <%= if @open do %>
        <div class="filter-dropdown__menu" phx-click-away={"close_#{@event_prefix}"}>
          <div class="filter-dropdown__list">
            <%= for {value, option_label} <- @options do %>
              <button
                type="button"
                class={[
                  "filter-dropdown__item",
                  @current_value == value && "filter-dropdown__item--selected"
                ]}
                phx-click={"change_#{@event_prefix}"}
                phx-value-value={value}
              >
                {option_label}
              </button>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
