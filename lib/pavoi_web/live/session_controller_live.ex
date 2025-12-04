defmodule PavoiWeb.SessionControllerLive do
  @moduledoc """
  Compact controller view for mobile/tablet session management.
  Optimized for touch-based product navigation with:
  - Haptic feedback on product selection
  - Collapsible message and voice control panels
  - Dense auto-fill product grid
  """
  use PavoiWeb, :live_view

  on_mount {PavoiWeb.NavHooks, :set_current_page}

  import PavoiWeb.ViewHelpers

  alias Pavoi.Sessions

  @impl true
  def mount(%{"id" => session_id}, _session, socket) do
    session = Sessions.get_session!(session_id)
    message_presets = Sessions.list_message_presets()
    voice_control_enabled = Application.get_env(:pavoi, :features)[:voice_control_enabled]

    voice_assets = %{
      vad_worklet: PavoiWeb.Endpoint.static_path("/assets/vad/vad.worklet.bundle.min.js"),
      vad_model: PavoiWeb.Endpoint.static_path("/assets/vad/silero_vad.onnx"),
      ort_wasm: PavoiWeb.Endpoint.static_path("/assets/js/ort-wasm-simd-threaded.wasm"),
      ort_wasm_jsep: PavoiWeb.Endpoint.static_path("/assets/js/ort-wasm-simd-threaded.jsep.wasm")
    }

    socket =
      assign(socket,
        session: session,
        session_id: String.to_integer(session_id),
        page_title: "#{session.name} - Controller",
        current_session_product: nil,
        current_product: nil,
        current_position: nil,
        current_image_index: 0,
        total_products: length(session.session_products),
        host_message: nil,
        message_draft: "",
        selected_color: "amber",
        message_presets: message_presets,
        show_preset_modal: false,
        voice_assets: voice_assets,
        voice_control_enabled: voice_control_enabled
      )

    socket =
      if connected?(socket) do
        subscribe_to_session(session_id)
        load_initial_state(socket)
      else
        socket
      end

    {:ok, socket}
  end

  ## Event Handlers

  # Product Navigation - Jump to product
  @impl true
  def handle_event("jump_to_product", %{"position" => position}, socket) do
    position = String.to_integer(position)

    case Sessions.jump_to_product(socket.assigns.session_id, position) do
      {:ok, _new_state} ->
        {:noreply, socket}

      {:error, :invalid_position} ->
        {:noreply, put_flash(socket, :error, "Invalid product number")}
    end
  end

  # Next product (wraps to first)
  @impl true
  def handle_event("next_product", _params, socket) do
    current = socket.assigns.current_position || 0
    total = socket.assigns.total_products

    next_position =
      if current >= total do
        1
      else
        current + 1
      end

    Sessions.jump_to_product(socket.assigns.session_id, next_position)
    {:noreply, socket}
  end

  # Previous product (wraps to last)
  @impl true
  def handle_event("previous_product", _params, socket) do
    current = socket.assigns.current_position || 1
    total = socket.assigns.total_products

    prev_position =
      if current <= 1 do
        total
      else
        current - 1
      end

    Sessions.jump_to_product(socket.assigns.session_id, prev_position)
    {:noreply, socket}
  end

  # Host Message Controls
  @impl true
  def handle_event("send_host_message", %{"message" => message_text}, socket) do
    color = socket.assigns.selected_color

    case Sessions.send_host_message(socket.assigns.session_id, message_text, color) do
      {:ok, _state} ->
        socket =
          socket
          |> assign(:message_draft, message_text)
          |> put_flash(:info, "Message sent")

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
  def handle_event("select_color", %{"color" => color}, socket) do
    {:noreply, assign(socket, :selected_color, color)}
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
        case Sessions.send_host_message(socket.assigns.session_id, text, color) do
          {:ok, _state} ->
            socket =
              socket
              |> assign(:message_draft, text)
              |> assign(:show_preset_modal, false)
              |> put_flash(:info, "Message sent")

            {:noreply, socket}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Failed to send message")}
        end
    end
  end

  @impl true
  def handle_event("create_preset", %{"message_text" => message_text, "color" => color}, socket) do
    case Sessions.create_message_preset(%{message_text: message_text, color: color}) do
      {:ok, _preset} ->
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

    case Sessions.get_session_state(session_id) do
      {:ok, %{current_session_product_id: nil}} ->
        case Sessions.initialize_session_state(session_id) do
          {:ok, state} -> load_state_from_session_state(socket, state)
          {:error, _} -> socket
        end

      {:ok, state} ->
        load_state_from_session_state(socket, state)

      {:error, :not_found} ->
        case Sessions.initialize_session_state(session_id) do
          {:ok, state} -> load_state_from_session_state(socket, state)
          {:error, _} -> socket
        end
    end
  end

  defp load_by_session_product_id(socket, session_product_id, image_index) do
    session_product = Sessions.get_session_product!(session_product_id)
    product = session_product.product
    session = socket.assigns.session

    display_position =
      session.session_products
      |> Enum.sort_by(& &1.position)
      |> Enum.find_index(&(&1.id == session_product_id))
      |> case do
        nil -> session_product.position
        index -> index + 1
      end

    assign(socket,
      current_session_product: session_product,
      current_product: product,
      current_image_index: image_index,
      current_position: display_position
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
  end

  ## Template Helpers

  def primary_image(product) do
    product.product_images
    |> Enum.find(& &1.is_primary)
    |> case do
      nil -> List.first(product.product_images)
      image -> image
    end
  end
end
