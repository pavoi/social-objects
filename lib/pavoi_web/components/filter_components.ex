defmodule PavoiWeb.FilterComponents do
  @moduledoc """
  Reusable filter dropdown components with unified styling.

  These components provide a consistent dropdown filter experience across all pages,
  matching the style used in the Creators page.
  """
  use Phoenix.Component

  import PavoiWeb.CoreComponents

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
