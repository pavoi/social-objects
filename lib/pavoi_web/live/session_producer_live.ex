defmodule PavoiWeb.SessionProducerLive do
  @moduledoc """
  Producer control panel for managing live streaming sessions.
  This view provides:
  - Full navigation controls (keyboard and clicks)
  - Host message composition and sending
  - View mode toggling (fullscreen config, split-screen, fullscreen host preview)
  - Real-time synchronization with host view
  """
  use PavoiWeb, :live_view

  on_mount {PavoiWeb.NavHooks, :set_current_page}

  import PavoiWeb.ViewHelpers
  import PavoiWeb.ThemeComponents

  alias Pavoi.Sessions
  alias Pavoi.Sessions.SessionProduct

  @impl true
  def mount(%{"id" => session_id}, _session, socket) do
    session = Sessions.get_session!(session_id)
    message_presets = Sessions.list_message_presets()

    socket =
      assign(socket,
        session: session,
        session_id: String.to_integer(session_id),
        page_title: "#{session.name} - Producer Console",
        current_session_product: nil,
        current_product: nil,
        current_position: nil,
        current_image_index: 0,
        talking_points_html: nil,
        product_images: [],
        total_products: length(session.session_products),
        host_message: nil,
        view_mode: :split_screen,
        message_draft: "",
        message_presets: message_presets,
        show_preset_modal: false
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

  ## Event Handlers

  # View Mode Controls
  @impl true
  def handle_event("set_view_mode", %{"mode" => mode}, socket) do
    view_mode = String.to_atom(mode)
    {:noreply, assign(socket, :view_mode, view_mode)}
  end

  # PRIMARY NAVIGATION: Direct jump to product by number
  @impl true
  def handle_event("jump_to_product", %{"position" => position}, socket) do
    position = String.to_integer(position)

    case Sessions.jump_to_product(socket.assigns.session_id, position) do
      {:ok, new_state} ->
        socket =
          push_patch(socket,
            to:
              ~p"/sessions/#{socket.assigns.session_id}/producer?sp=#{new_state.current_session_product_id}&img=0"
          )

        {:noreply, socket}

      {:error, :invalid_position} ->
        {:noreply, put_flash(socket, :error, "Invalid product number")}
    end
  end

  # CONVENIENCE: Sequential next/previous with arrow keys
  @impl true
  def handle_event("next_product", _params, socket) do
    case Sessions.advance_to_next_product(socket.assigns.session_id) do
      {:ok, new_state} ->
        socket =
          push_patch(socket,
            to:
              ~p"/sessions/#{socket.assigns.session_id}/producer?sp=#{new_state.current_session_product_id}&img=#{new_state.current_image_index}"
          )

        {:noreply, socket}

      {:error, :end_of_session} ->
        {:noreply, put_flash(socket, :info, "End of session reached")}
    end
  end

  @impl true
  def handle_event("previous_product", _params, socket) do
    case Sessions.go_to_previous_product(socket.assigns.session_id) do
      {:ok, new_state} ->
        socket =
          push_patch(socket,
            to:
              ~p"/sessions/#{socket.assigns.session_id}/producer?sp=#{new_state.current_session_product_id}&img=#{new_state.current_image_index}"
          )

        {:noreply, socket}

      {:error, :start_of_session} ->
        {:noreply, put_flash(socket, :info, "Already at first product")}
    end
  end

  @impl true
  def handle_event("next_image", _params, socket) do
    case Sessions.cycle_product_image(socket.assigns.session_id, :next) do
      {:ok, _state} -> {:noreply, socket}
      {:error, _} -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("previous_image", _params, socket) do
    case Sessions.cycle_product_image(socket.assigns.session_id, :previous) do
      {:ok, _state} -> {:noreply, socket}
      {:error, _} -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("jump_to_first", _params, socket) do
    # Jump to position 1 (first product)
    case Sessions.jump_to_product(socket.assigns.session_id, 1) do
      {:ok, new_state} ->
        socket =
          push_patch(socket,
            to:
              ~p"/sessions/#{socket.assigns.session_id}/producer?sp=#{new_state.current_session_product_id}&img=0"
          )

        {:noreply, socket}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("jump_to_last", _params, socket) do
    # Jump to last product (total_products)
    last_position = socket.assigns.total_products

    case Sessions.jump_to_product(socket.assigns.session_id, last_position) do
      {:ok, new_state} ->
        socket =
          push_patch(socket,
            to:
              ~p"/sessions/#{socket.assigns.session_id}/producer?sp=#{new_state.current_session_product_id}&img=0"
          )

        {:noreply, socket}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  # Image loaded events from LQIP component - just acknowledge, no action needed
  @impl true
  def handle_event("image_loaded", _params, socket) do
    {:noreply, socket}
  end

  # Host Message Controls
  @impl true
  def handle_event("send_host_message", %{"message" => message_text}, socket) do
    case Sessions.send_host_message(socket.assigns.session_id, message_text) do
      {:ok, _state} ->
        socket =
          socket
          |> assign(:message_draft, message_text)
          |> put_flash(:info, "Message sent to host")

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to send message")}
    end
  end

  @impl true
  def handle_event("update_message_draft", %{"message" => message_text}, socket) do
    {:noreply, assign(socket, :message_draft, message_text)}
  end

  @impl true
  def handle_event("clear_host_message", _params, socket) do
    case Sessions.clear_host_message(socket.assigns.session_id) do
      {:ok, _state} ->
        {:noreply, put_flash(socket, :info, "Message cleared")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to clear message")}
    end
  end

  # Message Preset Controls
  @impl true
  def handle_event("open_preset_modal", _params, socket) do
    {:noreply, assign(socket, :show_preset_modal, true)}
  end

  @impl true
  def handle_event("skip", _params, socket) do
    # No-op event to prevent modal clicks from bubbling up
    {:noreply, socket}
  end

  @impl true
  def handle_event("close_preset_modal", _params, socket) do
    {:noreply, assign(socket, :show_preset_modal, false)}
  end

  @impl true
  def handle_event("select_preset", %{"id" => preset_id}, socket) do
    preset = Enum.find(socket.assigns.message_presets, &(&1.id == preset_id))

    case preset do
      nil ->
        {:noreply, put_flash(socket, :error, "Preset not found")}

      %{message_text: text, color: color} ->
        # Immediately send the preset message
        case Sessions.send_host_message(socket.assigns.session_id, text, color) do
          {:ok, _state} ->
            socket =
              socket
              |> assign(:message_draft, text)
              |> assign(:show_preset_modal, false)
              |> put_flash(:info, "Message sent to host")

            {:noreply, socket}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Failed to send message")}
        end
    end
  end

  @impl true
  def handle_event(
        "create_preset",
        %{"message_text" => message_text, "color" => color},
        socket
      ) do
    case Sessions.create_message_preset(%{
           message_text: message_text,
           color: color
         }) do
      {:ok, _preset} ->
        # Reload presets
        message_presets = Sessions.list_message_presets()

        socket =
          socket
          |> assign(:message_presets, message_presets)
          |> put_flash(:info, "Preset created")

        {:noreply, socket}

      {:error, changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
          |> Enum.map_join("; ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)

        {:noreply, put_flash(socket, :error, "Failed to create preset: #{errors}")}
    end
  end

  @impl true
  def handle_event("delete_preset", %{"id" => preset_id}, socket) do
    preset = Enum.find(socket.assigns.message_presets, &(&1.id == preset_id))

    case preset do
      nil ->
        {:noreply, put_flash(socket, :error, "Preset not found")}

      preset ->
        case Sessions.delete_message_preset(preset) do
          {:ok, _} ->
            # Reload presets
            message_presets = Sessions.list_message_presets()

            socket =
              socket
              |> assign(:message_presets, message_presets)
              |> put_flash(:info, "Preset deleted")

            {:noreply, socket}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Failed to delete preset")}
        end
    end
  end

  # Handle PubSub broadcasts from other clients
  @impl true
  def handle_info({:state_changed, new_state}, socket) do
    socket = load_state_from_session_state(socket, new_state)
    {:noreply, socket}
  end

  ## Private Helpers

  defp subscribe_to_session(session_id) do
    Phoenix.PubSub.subscribe(Pavoi.PubSub, "session:#{session_id}:state")
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

    # Load host message if present and populate message draft
    socket =
      if state.current_host_message_text do
        socket
        |> assign(:host_message, %{
          text: state.current_host_message_text,
          id: state.current_host_message_id,
          timestamp: state.current_host_message_timestamp,
          color: state.current_host_message_color || Sessions.default_message_color()
        })
        |> assign(:message_draft, state.current_host_message_text)
      else
        socket
        |> assign(:host_message, nil)
        |> assign(:message_draft, "")
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

  # Template helper to get primary image from product
  def primary_image(product) do
    product.product_images
    |> Enum.find(& &1.is_primary)
    |> case do
      nil -> List.first(product.product_images)
      image -> image
    end
  end
end
