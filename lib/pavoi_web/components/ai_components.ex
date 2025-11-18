defmodule PavoiWeb.AIComponents do
  @moduledoc """
  UI components for AI-powered features like talking points generation.
  """

  use Phoenix.Component
  import PavoiWeb.CoreComponents
  alias Phoenix.LiveView.JS

  @doc """
  Renders a persistent progress banner for talking points generation.

  Shows real-time progress in a flash-like banner at the top of the page.
  Auto-dismisses after completion.

  ## Attributes
  - `generation` - TalkingPointsGeneration struct with progress info (nil if not active)
  - `current_product` - Name of the product currently being processed
  """
  attr :generation, :map, default: nil
  attr :current_product, :string, default: nil

  def generation_progress_banner(assigns) do
    ~H"""
    <div
      :if={@generation && @generation.status in ["pending", "processing"]}
      id="generation-progress-banner"
      class="toast"
      role="alert"
    >
      <div class="toast__content toast__content--info">
        <.icon name="hero-arrow-path" class="spinner spinner--spinning" />
        <div class="toast__text">
          <div class="toast__title">Generating talking points...</div>
          <div class="toast__details">
            {@generation.completed_count + @generation.failed_count + 1} of {@generation.total_count} products
            <%= if @current_product do %>
              · <em>{@current_product}</em>
            <% end %>
          </div>
        </div>
      </div>
    </div>

    <div
      :if={@generation && @generation.status in ["completed", "partial", "failed"]}
      id="generation-complete-banner"
      class="toast"
      role="alert"
      phx-mounted={
        JS.transition("fade-in-scale")
        |> JS.hide(time: 5000, to: "#generation-complete-banner", transition: "fade-out-scale")
      }
    >
      <div class={[
        "toast__content",
        @generation.status == "completed" && "toast__content--success",
        @generation.status == "partial" && "toast__content--warning",
        @generation.status == "failed" && "toast__content--error"
      ]}>
        <%= if @generation.status == "completed" do %>
          <.icon name="hero-check-circle" class="spinner" />
        <% end %>
        <%= if @generation.status == "partial" do %>
          <.icon name="hero-exclamation-triangle" class="spinner" />
        <% end %>
        <%= if @generation.status == "failed" do %>
          <.icon name="hero-x-circle" class="spinner" />
        <% end %>

        <div class="toast__text">
          <%= if @generation.status == "completed" do %>
            <div class="toast__title">Talking points generated!</div>
            <div class="toast__details">
              Successfully generated for all {@generation.completed_count} products
            </div>
          <% end %>

          <%= if @generation.status == "partial" do %>
            <div class="toast__title">Partially complete</div>
            <div class="toast__details">
              {@generation.completed_count} succeeded, {@generation.failed_count} failed
            </div>
          <% end %>

          <%= if @generation.status == "failed" do %>
            <div class="toast__title">Generation failed</div>
            <div class="toast__details">
              Failed to generate talking points
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a progress modal for talking points generation.

  Shows real-time progress for batch generation with current product,
  success/failure counts, and any errors that occurred.

  ## Attributes
  - `show` - Boolean to control visibility
  - `generation` - TalkingPointsGeneration struct with progress info
  - `current_product` - Name of the product currently being processed
  - `on_close` - Event to trigger when closing the modal
  """
  attr :show, :boolean, default: false
  attr :generation, :map, required: true
  attr :current_product, :string, default: nil
  attr :on_close, :string, required: true

  def generation_progress_modal(assigns) do
    ~H"""
    <div
      :if={@show}
      class="modal-overlay"
      phx-click-away={@on_close}
      phx-window-keydown={@on_close}
      phx-key="escape"
    >
      <div
        class="modal-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="generation-progress-title"
      >
        <div class="modal-header">
          <h2 id="generation-progress-title" class="modal-title">
            {generation_title(@generation)}
          </h2>
        </div>

        <div class="modal-body">
          <%= if @generation.status == "processing" do %>
            <div class="progress-container">
              <div class="progress-spinner">
                <.spinner />
              </div>

              <div class="progress-details">
                <p class="progress-status">
                  Generating {@generation.completed_count + 1} of {@generation.total_count} products...
                </p>

                <%= if @current_product do %>
                  <p class="current-product">
                    Current: <strong>{@current_product}</strong>
                  </p>
                <% end %>

                <div class="progress-bar-container">
                  <div class="progress-bar" style={"width: #{calculate_progress(@generation)}%"}>
                  </div>
                </div>

                <p class="progress-counts">
                  ✓ {@generation.completed_count} succeeded
                  <%= if @generation.failed_count > 0 do %>
                    · ✗ {@generation.failed_count} failed
                  <% end %>
                </p>
              </div>
            </div>
          <% else %>
            <div class="completion-summary">
              <%= if @generation.status == "completed" do %>
                <div class="completion-icon success">✓</div>
                <p class="completion-message">
                  Successfully generated talking points for {@generation.completed_count} product{if @generation.completed_count !=
                                                                                                       1,
                                                                                                     do:
                                                                                                       "s"}!
                </p>
              <% end %>

              <%= if @generation.status == "partial" do %>
                <div class="completion-icon partial">⚠</div>
                <p class="completion-message">
                  Generated talking points for {@generation.completed_count} of {@generation.total_count} products.
                </p>
                <p class="completion-details">
                  {@generation.failed_count} product{if @generation.failed_count != 1, do: "s"} failed to generate.
                </p>
              <% end %>

              <%= if @generation.status == "failed" do %>
                <div class="completion-icon error">✗</div>
                <p class="completion-message">
                  Failed to generate talking points for all products.
                </p>
              <% end %>

              <%= if map_size(@generation.errors) > 0 do %>
                <details class="error-details">
                  <summary>View errors ({map_size(@generation.errors)})</summary>
                  <ul class="error-list">
                    <%= for {_product_id, error} <- @generation.errors do %>
                      <li>{error}</li>
                    <% end %>
                  </ul>
                </details>
              <% end %>
            </div>
          <% end %>
        </div>

        <div class="modal-footer">
          <%= if @generation.status == "processing" do %>
            <button type="button" class="button button-secondary" phx-click={@on_close}>
              Close (job continues)
            </button>
          <% else %>
            <button type="button" class="button button-primary" phx-click={@on_close}>
              Done
            </button>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a simple loading indicator for inline generation.
  """
  attr :show, :boolean, default: false

  def generating_indicator(assigns) do
    ~H"""
    <div :if={@show} class="generating-indicator">
      <.spinner />
      <span>Generating...</span>
    </div>
    """
  end

  @doc """
  Renders a small spinner animation.
  """
  def spinner(assigns) do
    ~H"""
    <svg class="spinner" viewBox="0 0 50 50">
      <circle class="spinner-path" cx="25" cy="25" r="20" fill="none" stroke-width="5"></circle>
    </svg>
    """
  end

  # Helper functions

  defp generation_title(generation) do
    case generation.status do
      "processing" -> "Generating Talking Points"
      "completed" -> "Generation Complete"
      "partial" -> "Generation Partially Complete"
      "failed" -> "Generation Failed"
      _ -> "Talking Points Generation"
    end
  end

  defp calculate_progress(generation) do
    total = generation.completed_count + generation.failed_count

    if generation.total_count > 0 do
      round(total / generation.total_count * 100)
    else
      0
    end
  end
end
