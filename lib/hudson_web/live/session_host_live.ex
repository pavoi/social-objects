defmodule HudsonWeb.SessionHostLive do
  @moduledoc """
  Read-only host view for displaying product information during live streaming.
  This view is controlled remotely by the producer and displays:
  - Current product information
  - Product images
  - Talking points
  - Live messages from producer (as floating banner)
  """
  use HudsonWeb, :live_view

  on_mount {HudsonWeb.NavHooks, :set_current_page}

  alias Hudson.Sessions
  alias Hudson.Sessions.SessionProduct

  @impl true
  def mount(%{"id" => session_id}, _session, socket) do
    session = Sessions.get_session!(session_id)

    socket =
      assign(socket,
        session: session,
        session_id: String.to_integer(session_id),
        page_title: "#{session.name} - Host View",
        current_session_product: nil,
        current_product: nil,
        current_position: nil,
        current_image_index: 0,
        talking_points_html: nil,
        product_images: [],
        total_products: length(session.session_products),
        host_message: nil
      )

    # Subscribe to PubSub ONLY after WebSocket connection
    socket =
      if connected?(socket) do
        subscribe_to_session(session_id)
        load_initial_state(socket)
      else
        socket
      end

    # Note: Not using temporary_assigns for product display data
    # because it needs to persist across renders for the UI to work correctly
    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Handle URL parameter changes (from push_patch or back button)
    socket =
      case params do
        %{"sp" => sp_id, "img" => img_idx} ->
          load_by_session_product_id(socket, String.to_integer(sp_id), String.to_integer(img_idx))

        _ ->
          socket
      end

    {:noreply, socket}
  end

  # Image loaded events from LQIP component - just acknowledge, no action needed
  @impl true
  def handle_event("image_loaded", _params, socket) do
    {:noreply, socket}
  end

  # Handle PubSub broadcasts from producer
  @impl true
  def handle_info({:state_changed, new_state}, socket) do
    socket = load_state_from_session_state(socket, new_state)
    {:noreply, socket}
  end

  ## Private Helpers

  defp subscribe_to_session(session_id) do
    Phoenix.PubSub.subscribe(Hudson.PubSub, "session:#{session_id}:state")
  end

  defp load_initial_state(socket) do
    session_id = socket.assigns.session_id

    # Try to load existing state, or initialize to first product
    case Sessions.get_session_state(session_id) do
      {:ok, %{current_session_product_id: nil}} ->
        # State exists but no product selected - initialize to first
        case Sessions.initialize_session_state(session_id) do
          {:ok, state} -> load_state_from_session_state(socket, state)
          {:error, _} -> socket
        end

      {:ok, state} ->
        load_state_from_session_state(socket, state)

      {:error, :not_found} ->
        # Initialize to first product
        case Sessions.initialize_session_state(session_id) do
          {:ok, state} -> load_state_from_session_state(socket, state)
          {:error, _} -> socket
        end
    end
  end

  defp load_by_session_product_id(socket, session_product_id, image_index) do
    session_product = Sessions.get_session_product!(session_product_id)
    product = session_product.product

    # Calculate display position (1-based index in sorted list)
    session = socket.assigns.session

    display_position =
      session.session_products
      |> Enum.sort_by(& &1.position)
      |> Enum.find_index(&(&1.id == session_product_id))
      |> case do
        # Fallback to raw position
        nil -> session_product.position
        # Convert to 1-based
        index -> index + 1
      end

    assign(socket,
      current_session_product: session_product,
      current_product: product,
      current_image_index: image_index,
      current_position: display_position,
      talking_points_html:
        render_markdown(session_product.featured_talking_points_md || product.talking_points_md),
      product_images: product.product_images
    )
  end

  defp load_state_from_session_state(socket, state) do
    socket =
      if state.current_session_product_id do
        load_by_session_product_id(
          socket,
          state.current_session_product_id,
          state.current_image_index
        )
      else
        socket
      end

    # Load host message if present
    socket =
      if state.current_host_message_text do
        assign(socket, :host_message, %{
          text: state.current_host_message_text,
          id: state.current_host_message_id,
          timestamp: state.current_host_message_timestamp
        })
      else
        assign(socket, :host_message, nil)
      end

    socket
  end

  defp render_markdown(nil), do: nil

  defp render_markdown(markdown) do
    case Earmark.as_html(markdown) do
      {:ok, html, _} -> Phoenix.HTML.raw(html)
      _ -> nil
    end
  end

  ## Helper functions for template

  def get_effective_name(session_product) do
    SessionProduct.effective_name(session_product)
  end

  def get_effective_prices(session_product) do
    SessionProduct.effective_prices(session_product)
  end
end
