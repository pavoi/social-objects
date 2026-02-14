defmodule SocialObjectsWeb.ProductHostLive.Index do
  @moduledoc """
  Host view for displaying product information during live streaming.
  This view supports the same keyboard shortcuts as the controller view and displays:
  - Current product information
  - Product images
  - Talking points
  - Live messages from controller (as floating banner)

  Changes made from either controller or host view are synchronized via PubSub.
  """
  use SocialObjectsWeb, :live_view

  on_mount {SocialObjectsWeb.NavHooks, :set_current_page}

  alias SocialObjects.ProductSets
  alias SocialObjectsWeb.BrandRoutes
  import SocialObjectsWeb.BrandPermissions
  import SocialObjectsWeb.ParamHelpers

  @impl true
  def mount(%{"id" => product_set_id_param}, _session, socket) do
    case parse_id(product_set_id_param) do
      {:ok, product_set_id} ->
        mount_with_product_set(socket, product_set_id)

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid product set ID")
         |> push_navigate(to: ~p"/products")}
    end
  end

  defp mount_with_product_set(socket, product_set_id) do
    brand_id = socket.assigns.current_brand.id
    product_set = ProductSets.get_product_set!(brand_id, product_set_id)

    socket =
      assign(socket,
        product_set: product_set,
        product_set_id: product_set_id,
        page_title: "#{product_set.name} - Host View",
        current_product_set_product: nil,
        current_product: nil,
        current_position: nil,
        current_image_index: 0,
        talking_points_html: nil,
        product_images: [],
        total_products: length(product_set.product_set_products),
        host_message: nil,
        products_panel_collapsed: true,
        product_set_panel_collapsed: true
      )

    # Subscribe to PubSub ONLY after WebSocket connection
    socket =
      if connected?(socket) do
        _ = subscribe_to_product_set(product_set_id)
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
          with {:ok, sp_id_int} <- parse_id(sp_id),
               {:ok, img_idx_int} <- parse_integer(img_idx) do
            load_by_product_set_product_id(socket, sp_id_int, img_idx_int)
          else
            :error -> socket
          end

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

  # PRIMARY NAVIGATION: Direct jump to product by number
  @impl true
  def handle_event("jump_to_product", %{"position" => position_param}, socket) do
    authorize socket, :admin do
      case parse_integer(position_param) do
        {:ok, position} ->
          case ProductSets.jump_to_product(socket.assigns.product_set_id, position) do
            {:ok, new_state} ->
              socket =
                push_patch(socket,
                  to:
                    BrandRoutes.brand_path(
                      socket.assigns.current_brand,
                      "/products/#{socket.assigns.product_set_id}/host?sp=#{new_state.current_product_set_product_id}&img=0",
                      socket.assigns.current_host
                    )
                )

              {:noreply, socket}

            {:error, :invalid_position} ->
              {:noreply, put_flash(socket, :error, "Invalid product number")}
          end

        :error ->
          {:noreply, put_flash(socket, :error, "Invalid position")}
      end
    end
  end

  # CONVENIENCE: Sequential next/previous with arrow keys
  @impl true
  def handle_event("next_product", _params, socket) do
    authorize socket, :admin do
      case ProductSets.advance_to_next_product(socket.assigns.product_set_id) do
        {:ok, new_state} ->
          socket =
            push_patch(socket,
              to:
                BrandRoutes.brand_path(
                  socket.assigns.current_brand,
                  "/products/#{socket.assigns.product_set_id}/host?sp=#{new_state.current_product_set_product_id}&img=#{new_state.current_image_index}",
                  socket.assigns.current_host
                )
            )

          {:noreply, socket}

        {:error, :end_of_product_set} ->
          {:noreply, put_flash(socket, :info, "End of product set reached")}
      end
    end
  end

  @impl true
  def handle_event("previous_product", _params, socket) do
    authorize socket, :admin do
      case ProductSets.go_to_previous_product(socket.assigns.product_set_id) do
        {:ok, new_state} ->
          socket =
            push_patch(socket,
              to:
                BrandRoutes.brand_path(
                  socket.assigns.current_brand,
                  "/products/#{socket.assigns.product_set_id}/host?sp=#{new_state.current_product_set_product_id}&img=#{new_state.current_image_index}",
                  socket.assigns.current_host
                )
            )

          {:noreply, socket}

        {:error, :start_of_product_set} ->
          {:noreply, put_flash(socket, :info, "Already at first product")}
      end
    end
  end

  @impl true
  def handle_event("next_image", _params, socket) do
    authorize socket, :admin do
      case ProductSets.cycle_product_image(socket.assigns.product_set_id, :next) do
        {:ok, _state} -> {:noreply, socket}
        {:error, _} -> {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_event("previous_image", _params, socket) do
    authorize socket, :admin do
      case ProductSets.cycle_product_image(socket.assigns.product_set_id, :previous) do
        {:ok, _state} -> {:noreply, socket}
        {:error, _} -> {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_event("goto_image", %{"index" => index_param}, socket) do
    authorize socket, :admin do
      case parse_integer(index_param) do
        {:ok, index} ->
          case ProductSets.set_image_index(socket.assigns.product_set_id, index) do
            {:ok, _state} -> {:noreply, socket}
            {:error, _} -> {:noreply, socket}
          end

        :error ->
          {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_event("toggle_products_panel", _params, socket) do
    {:noreply, update(socket, :products_panel_collapsed, &(!&1))}
  end

  @impl true
  def handle_event("toggle_product_set_panel", _params, socket) do
    authorize socket, :admin do
      new_collapsed = !socket.assigns.product_set_panel_collapsed

      # Broadcast to controller so toggle stays in sync
      _ =
        Phoenix.PubSub.broadcast(
          SocialObjects.PubSub,
          "product_set:#{socket.assigns.product_set_id}:ui",
          {:product_set_notes_toggle, !new_collapsed}
        )

      {:noreply, assign(socket, :product_set_panel_collapsed, new_collapsed)}
    end
  end

  @impl true
  def handle_event("select_product_from_panel", %{"position" => position_param}, socket) do
    authorize socket, :admin do
      case parse_integer(position_param) do
        {:ok, position} ->
          case ProductSets.jump_to_product(socket.assigns.product_set_id, position) do
            {:ok, new_state} ->
              socket =
                socket
                |> assign(:products_panel_collapsed, true)
                |> push_patch(
                  to:
                    BrandRoutes.brand_path(
                      socket.assigns.current_brand,
                      "/products/#{socket.assigns.product_set_id}/host?sp=#{new_state.current_product_set_product_id}&img=0",
                      socket.assigns.current_host
                    )
                )

              {:noreply, socket}

            {:error, _} ->
              {:noreply, socket}
          end

        :error ->
          {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_event("jump_to_first", _params, socket) do
    authorize socket, :admin do
      # Jump to position 1 (first product)
      case ProductSets.jump_to_product(socket.assigns.product_set_id, 1) do
        {:ok, new_state} ->
          socket =
            push_patch(socket,
              to:
                BrandRoutes.brand_path(
                  socket.assigns.current_brand,
                  "/products/#{socket.assigns.product_set_id}/host?sp=#{new_state.current_product_set_product_id}&img=0",
                  socket.assigns.current_host
                )
            )

          {:noreply, socket}

        {:error, _} ->
          {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_event("jump_to_last", _params, socket) do
    authorize socket, :admin do
      # Jump to last product (total_products)
      last_position = socket.assigns.total_products

      case ProductSets.jump_to_product(socket.assigns.product_set_id, last_position) do
        {:ok, new_state} ->
          socket =
            push_patch(socket,
              to:
                BrandRoutes.brand_path(
                  socket.assigns.current_brand,
                  "/products/#{socket.assigns.product_set_id}/host?sp=#{new_state.current_product_set_product_id}&img=0",
                  socket.assigns.current_host
                )
            )

          {:noreply, socket}

        {:error, _} ->
          {:noreply, socket}
      end
    end
  end

  # Handle PubSub broadcasts from controller
  @impl true
  def handle_info({:state_changed, new_state}, socket) do
    socket = load_state_from_product_set_state(socket, new_state)
    {:noreply, socket}
  end

  # Handle product set notes toggle from controller
  @impl true
  def handle_info({:product_set_notes_toggle, visible}, socket) do
    {:noreply, assign(socket, :product_set_panel_collapsed, !visible)}
  end

  ## Private Helpers

  defp subscribe_to_product_set(product_set_id) do
    _ = Phoenix.PubSub.subscribe(SocialObjects.PubSub, "product_set:#{product_set_id}:state")
    _ = Phoenix.PubSub.subscribe(SocialObjects.PubSub, "product_set:#{product_set_id}:ui")
  end

  defp load_initial_state(socket) do
    product_set_id = socket.assigns.product_set_id

    case ProductSets.get_product_set_state(product_set_id) do
      {:ok, %{current_product_set_product_id: id} = state} when not is_nil(id) ->
        load_state_from_product_set_state(socket, state)

      _no_state_or_no_product ->
        case ProductSets.initialize_product_set_state(product_set_id) do
          {:ok, state} -> load_state_from_product_set_state(socket, state)
          {:error, _} -> socket
        end
    end
  end

  defp load_by_product_set_product_id(socket, product_set_product_id, image_index) do
    product_set_product = ProductSets.get_product_set_product!(product_set_product_id)
    product = product_set_product.product

    # Calculate display position (1-based index in sorted list)
    product_set = socket.assigns.product_set

    display_position =
      product_set.product_set_products
      |> Enum.sort_by(& &1.position)
      |> Enum.find_index(&(&1.id == product_set_product_id))
      |> case do
        # Fallback to raw position
        nil -> product_set_product.position
        # Convert to 1-based
        index -> index + 1
      end

    assign(socket,
      current_product_set_product: product_set_product,
      current_product: product,
      current_image_index: image_index,
      current_position: display_position,
      talking_points_html:
        render_markdown(
          product_set_product.featured_talking_points_md || product.talking_points_md
        ),
      product_images: product.product_images
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

    # Load host message if present
    socket =
      if state.current_host_message_text do
        assign(socket, :host_message, %{
          text: state.current_host_message_text,
          id: state.current_host_message_id,
          timestamp: state.current_host_message_timestamp,
          color: state.current_host_message_color || ProductSets.default_message_color()
        })
      else
        assign(socket, :host_message, nil)
      end

    socket
  end

  defp render_markdown(nil), do: nil

  defp render_markdown(markdown) do
    case Earmark.as_html(markdown) do
      {:ok, html, _} ->
        # Convert paragraphs to list items for bullet display
        html
        |> convert_paragraphs_to_list_items()
        |> Phoenix.HTML.raw()

      _ ->
        nil
    end
  end

  # Convert <p> tags to <li> tags wrapped in <ul> for bullet display
  defp convert_paragraphs_to_list_items(html) do
    if already_a_list?(html), do: html, else: convert_to_bullet_list(html)
  end

  defp already_a_list?(html), do: String.contains?(html, "<ul>") or String.contains?(html, "<ol>")

  defp convert_to_bullet_list(html) do
    content =
      html
      |> String.replace(~r/<p>/, "<li>")
      |> String.replace(~r/<\/p>/, "</li>")

    if String.contains?(content, "<li>") do
      "<ul class=\"host-talking-points-list\">#{content}</ul>"
    else
      content
    end
  end
end
