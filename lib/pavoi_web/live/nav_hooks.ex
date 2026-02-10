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

  # Brand pages
  defp get_current_page(PavoiWeb.ProductSetsLive.Index), do: :product_sets
  defp get_current_page(PavoiWeb.CreatorsLive.Index), do: :creators
  defp get_current_page(PavoiWeb.VideosLive.Index), do: :videos
  defp get_current_page(PavoiWeb.TiktokLive.Index), do: :streams
  defp get_current_page(PavoiWeb.ShopAnalyticsLive.Index), do: :shop_analytics
  defp get_current_page(PavoiWeb.ReadmeLive.Index), do: :readme

  # Admin pages - return :admin so nav shows but no tab is highlighted
  defp get_current_page(PavoiWeb.AdminLive.Dashboard), do: :admin
  defp get_current_page(PavoiWeb.AdminLive.Brands), do: :admin
  defp get_current_page(PavoiWeb.AdminLive.Users), do: :admin
  defp get_current_page(PavoiWeb.AdminLive.Invites), do: :admin

  # Full-page views return nil so navbar doesn't show
  defp get_current_page(PavoiWeb.ProductSetHostLive.Index), do: nil
  defp get_current_page(PavoiWeb.ProductSetControllerLive.Index), do: nil
  defp get_current_page(PavoiWeb.TemplateEditorLive), do: nil
  defp get_current_page(_), do: nil
end
