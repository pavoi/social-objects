defmodule PavoiWeb.ProductSetControllerLive.Index do
  @moduledoc """
  Compact controller view for mobile/tablet product set management.
  Optimized for touch-based product navigation with:
  - Haptic feedback on product selection
  - Collapsible message and voice control panels
  - Dense auto-fill product grid
  """
  use PavoiWeb, :live_view

  on_mount {PavoiWeb.NavHooks, :set_current_page}

  import PavoiWeb.ViewHelpers

  alias Pavoi.ProductSets

  @impl true
  def mount(%{"id" => product_set_id}, _session, socket) do
    brand_id = socket.assigns.current_brand.id
    product_set = ProductSets.get_product_set!(brand_id, product_set_id)
    message_presets = ProductSets.list_message_presets(brand_id)
    voice_control_enabled = Application.get_env(:pavoi, :features)[:voice_control_enabled]

    voice_assets = %{
      vad_worklet: PavoiWeb.Endpoint.static_path("/assets/vad/vad.worklet.bundle.min.js"),
      vad_model: PavoiWeb.Endpoint.static_path("/assets/vad/silero_vad.onnx"),
      ort_wasm: PavoiWeb.Endpoint.static_path("/assets/js/ort-wasm-simd-threaded.wasm"),
      ort_wasm_jsep: PavoiWeb.Endpoint.static_path("/assets/js/ort-wasm-simd-threaded.jsep.wasm")
    }

    socket =
      assign(socket,
        brand_id: brand_id,
        product_set: product_set,
        product_set_id: String.to_integer(product_set_id),
        page_title: "#{product_set.name} - Controller",
        current_product_set_product: nil,
        current_product: nil,
        current_position: nil,
        current_image_index: 0,
        total_products: length(product_set.product_set_products),
        host_message: nil,
        message_draft: "",
        selected_color: "amber",
        message_panel_collapsed: true,
        message_presets: message_presets,
        show_preset_modal: false,
        voice_assets: voice_assets,
        voice_control_enabled: voice_control_enabled,
        product_set_notes_visible: false
      )

    socket =
      if connected?(socket) do
        subscribe_to_product_set(product_set_id)
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

    case ProductSets.jump_to_product(socket.assigns.product_set_id, position) do
      {:ok, _new_state} ->
        {:reply, %{success: true, position: position}, socket}

      {:error, :invalid_position} ->
        {:reply, %{success: false, error: "Product #{position} not found"}, socket}
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

    ProductSets.jump_to_product(socket.assigns.product_set_id, next_position)
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

    ProductSets.jump_to_product(socket.assigns.product_set_id, prev_position)
    {:noreply, socket}
  end

  # Product Set Notes Toggle (controls host view)
  @impl true
  def handle_event("toggle_product_set_notes", _params, socket) do
    new_visible = !socket.assigns.product_set_notes_visible

    # Broadcast to host view
    Phoenix.PubSub.broadcast(
      Pavoi.PubSub,
      "product_set:#{socket.assigns.product_set_id}:ui",
      {:product_set_notes_toggle, new_visible}
    )

    {:noreply, assign(socket, :product_set_notes_visible, new_visible)}
  end

  # Host Message Controls
  @impl true
  def handle_event("toggle_message_panel", _params, socket) do
    {:noreply, assign(socket, :message_panel_collapsed, !socket.assigns.message_panel_collapsed)}
  end

  @impl true
  def handle_event("send_host_message", %{"message" => message_text}, socket) do
    color = socket.assigns.selected_color

    case ProductSets.send_host_message(socket.assigns.product_set_id, message_text, color) do
      {:ok, _state} ->
        socket =
          socket
          |> assign(:message_draft, message_text)
          |> assign(:message_panel_collapsed, true)

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
    case ProductSets.clear_host_message(socket.assigns.product_set_id) do
      {:ok, _state} ->
        {:noreply, socket}

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
        case ProductSets.send_host_message(socket.assigns.product_set_id, text, color) do
          {:ok, _state} ->
            socket =
              socket
              |> assign(:message_draft, text)
              |> assign(:selected_color, color)
              |> assign(:show_preset_modal, false)
              |> assign(:message_panel_collapsed, true)

            {:noreply, socket}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Failed to send message")}
        end
    end
  end

  @impl true
  def handle_event("create_preset", %{"message_text" => message_text, "color" => color}, socket) do
    case ProductSets.create_message_preset(socket.assigns.brand_id, %{
           message_text: message_text,
           color: color
         }) do
      {:ok, _preset} ->
        message_presets = ProductSets.list_message_presets(socket.assigns.brand_id)

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
        case ProductSets.delete_message_preset(preset) do
          {:ok, _} ->
            message_presets = ProductSets.list_message_presets(socket.assigns.brand_id)

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
    socket = load_state_from_product_set_state(socket, new_state)
    {:noreply, socket}
  end

  # Handle product set notes toggle from host view
  @impl true
  def handle_info({:product_set_notes_toggle, visible}, socket) do
    {:noreply, assign(socket, :product_set_notes_visible, visible)}
  end

  ## Private Helpers

  defp subscribe_to_product_set(product_set_id) do
    Phoenix.PubSub.subscribe(Pavoi.PubSub, "product_set:#{product_set_id}:state")
    Phoenix.PubSub.subscribe(Pavoi.PubSub, "product_set:#{product_set_id}:ui")
  end

  defp load_initial_state(socket) do
    product_set_id = socket.assigns.product_set_id

    case ProductSets.get_product_set_state(product_set_id) do
      {:ok, %{current_product_set_product_id: nil}} ->
        case ProductSets.initialize_product_set_state(product_set_id) do
          {:ok, state} -> load_state_from_product_set_state(socket, state)
          {:error, _} -> socket
        end

      {:ok, state} ->
        load_state_from_product_set_state(socket, state)

      {:error, :not_found} ->
        case ProductSets.initialize_product_set_state(product_set_id) do
          {:ok, state} -> load_state_from_product_set_state(socket, state)
          {:error, _} -> socket
        end
    end
  end

  defp load_by_product_set_product_id(socket, product_set_product_id, image_index) do
    product_set_product = ProductSets.get_product_set_product!(product_set_product_id)
    product = product_set_product.product
    product_set = socket.assigns.product_set

    display_position =
      product_set.product_set_products
      |> Enum.sort_by(& &1.position)
      |> Enum.find_index(&(&1.id == product_set_product_id))
      |> case do
        nil -> product_set_product.position
        index -> index + 1
      end

    assign(socket,
      current_product_set_product: product_set_product,
      current_product: product,
      current_image_index: image_index,
      current_position: display_position
    )
  end

  defp load_state_from_product_set_state(socket, state) do
    socket =
      if state.current_product_set_product_id do
        load_by_product_set_product_id(
          socket,
          state.current_product_set_product_id,
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
        color: state.current_host_message_color || ProductSets.default_message_color()
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
