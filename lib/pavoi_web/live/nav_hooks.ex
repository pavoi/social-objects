defmodule PavoiWeb.NavHooks do
  @moduledoc """
  LiveView lifecycle hooks for navigation state.
  """

  def on_mount(:set_current_page, _params, _session, socket) do
    # Get the view module from the socket's private data
    view_module = socket.private[:phoenix_live_view][:view] || socket.view
    current_page = get_current_page(view_module)

    socket = Map.update!(socket, :assigns, &Map.put(&1, :current_page, current_page))
    {:cont, socket}
  end

  defp get_current_page(PavoiWeb.SessionsLive.Index), do: :sessions
  defp get_current_page(PavoiWeb.ProductsLive.Index), do: :products
  defp get_current_page(PavoiWeb.CreatorsLive.Index), do: :creators
  defp get_current_page(PavoiWeb.TiktokLive.Index), do: :live_streams
  # Controller and host views return nil so navbar doesn't show
  defp get_current_page(PavoiWeb.SessionHostLive), do: nil
  defp get_current_page(PavoiWeb.SessionControllerLive), do: nil
  defp get_current_page(_), do: nil
end
