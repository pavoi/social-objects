defmodule PavoiWeb.ThemeComponents do
  @moduledoc """
  Reusable components for theme management (light/dark mode).
  """
  use Phoenix.Component

  @doc """
  Renders a theme toggle button that switches between light and dark modes.

  The button uses the ThemeToggle JavaScript hook to manage state and persistence.
  Icons are shown/hidden based on the current theme via CSS.

  ## Example

      <.theme_toggle />
  """
  attr :class, :string, default: nil, doc: "Additional CSS classes"

  def theme_toggle(assigns) do
    ~H"""
    <button
      phx-hook="ThemeToggle"
      id="theme-toggle"
      class={["theme-toggle", @class]}
      aria-label="Toggle light/dark mode"
      title="Toggle theme"
      type="button"
    >
      <span class="theme-toggle__icon theme-toggle__icon--sun" aria-hidden="true">☼</span>
      <span class="theme-toggle__icon theme-toggle__icon--moon" aria-hidden="true">☾</span>
      <span class="sr-only">Toggle theme</span>
    </button>
    """
  end
end
