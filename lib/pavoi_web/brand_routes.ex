defmodule PavoiWeb.BrandRoutes do
  @moduledoc false

  alias Pavoi.Catalog.Brand

  def brand_home_path(%Brand{} = brand, current_host \\ nil) do
    brand_path(brand, "/readme", current_host)
  end

  def brand_home_path_for_host(%Brand{} = brand, current_host) do
    if brand.primary_domain && current_host == brand.primary_domain do
      "/readme"
    else
      "/b/#{brand.slug}/readme"
    end
  end

  def brand_path(brand, path, current_host \\ nil)

  def brand_path(%Brand{} = brand, path, current_host) when is_binary(path) do
    normalized = normalize_path(path)

    case brand.primary_domain do
      domain when is_binary(domain) and domain != "" ->
        cond do
          is_nil(current_host) ->
            "/b/#{brand.slug}#{normalized}"

          local_host?(current_host) ->
            "/b/#{brand.slug}#{normalized}"

          current_host == domain ->
            normalized

          true ->
            "https://#{domain}#{normalized}"
        end

      _ ->
        "/b/#{brand.slug}#{normalized}"
    end
  end

  def brand_path(nil, path, _current_host), do: normalize_path(path)

  def brand_url(%Brand{} = brand, path) when is_binary(path) do
    normalized = normalize_path(path)

    case brand.primary_domain do
      domain when is_binary(domain) and domain != "" ->
        "https://#{domain}#{normalized}"

      _ ->
        PavoiWeb.Endpoint.url() <> "/b/#{brand.slug}#{normalized}"
    end
  end

  def brand_invite_url(%Brand{} = brand, token) when is_binary(token) do
    path = "/invite/#{token}"

    case brand.primary_domain do
      domain when is_binary(domain) and domain != "" ->
        "https://#{domain}#{path}"

      _ ->
        PavoiWeb.Endpoint.url() <> path
    end
  end

  defp normalize_path(path) do
    if String.starts_with?(path, "/"), do: path, else: "/" <> path
  end

  defp local_host?(host) when is_binary(host) do
    host in ["localhost", "127.0.0.1", "0.0.0.0"]
  end

  defp local_host?(_host), do: false
end
