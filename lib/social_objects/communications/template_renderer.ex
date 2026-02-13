defmodule SocialObjects.Communications.TemplateRenderer do
  @moduledoc """
  Renders email templates for sending.

  Templates are stored as complete HTML. At send time, any Lark URLs
  are replaced with join URLs that capture SMS consent before redirect.
  Plain text version is auto-generated from HTML if not provided.
  """

  alias SocialObjects.Catalog.Brand
  alias SocialObjects.Communications.EmailTemplate
  alias SocialObjects.Outreach
  alias SocialObjects.Storage
  alias SocialObjectsWeb.BrandRoutes

  # Known Lark invite URL patterns to replace with join URLs
  @lark_url_pattern ~r{https://applink\.larksuite\.com/[^"'\s<>]+}
  @legacy_asset_hosts [
    "https://app.pavoi.com",
    "http://app.pavoi.com"
  ]

  @doc """
  Renders a template for sending to a specific creator.

  Substitutes template variables and replaces Lark URLs with join URLs.
  Returns {subject, html_body, text_body}
  """
  def render(%EmailTemplate{} = template, creator, %Brand{} = brand) do
    join_url = generate_join_url(brand, creator.id, template.lark_preset)
    unsubscribe_url = generate_unsubscribe_url(brand, creator.id)
    link_base_url = link_base_url(brand)
    asset_base_url = asset_base_url()
    brand_logo_url = brand_logo_url(brand, asset_base_url)

    variables = %{
      "creator_name" => creator_display_name(creator),
      "join_url" => join_url,
      "unsubscribe_url" => unsubscribe_url,
      "base_url" => link_base_url,
      "brand_logo_url" => brand_logo_url
    }

    html_body =
      template.html_body
      |> substitute_variables(variables)
      |> normalize_legacy_asset_hosts()
      |> absolutize_urls(link_base_url, asset_base_url)
      |> normalize_logo_image_dimensions(brand_logo_url)
      |> replace_lark_urls(join_url)

    text_body =
      if template.text_body && template.text_body != "" do
        template.text_body
        |> substitute_variables(variables)
        |> replace_lark_urls(join_url)
      else
        html_to_text(html_body)
      end

    subject = substitute_variables(template.subject, variables)

    {subject, html_body, text_body}
  end

  @doc """
  Renders page template HTML with brand-aware logo and absolute URLs.
  """
  def render_page_html(content, %Brand{} = brand) when is_binary(content) do
    link_base_url = link_base_url(brand)
    asset_base_url = asset_base_url()
    brand_logo_url = brand_logo_url(brand, asset_base_url)

    content
    |> substitute_variables(%{
      "base_url" => link_base_url,
      "brand_logo_url" => brand_logo_url
    })
    |> normalize_legacy_asset_hosts()
    |> absolutize_urls(link_base_url, asset_base_url)
    |> normalize_logo_image_dimensions(brand_logo_url)
  end

  def render_page_html(nil, _brand), do: nil

  @doc """
  Renders a template for preview (no URL replacement).
  Disables link clicks to prevent navigation to unsubstituted template URLs.

  Returns {subject, html_body}
  """
  def render_preview(%EmailTemplate{} = template) do
    # Inject CSS to disable link clicks in preview
    html_with_disabled_links =
      "<style>a { pointer-events: none; cursor: default; }</style>" <> (template.html_body || "")

    {template.subject, html_with_disabled_links}
  end

  defp generate_join_url(%Brand{} = brand, creator_id, lark_preset) do
    token = Outreach.generate_join_token(brand.id, creator_id, lark_preset)

    if use_brand_domains_in_outbound?() and not outbound_base_override?() do
      BrandRoutes.brand_url(brand, "/join/#{token}")
    else
      outbound_base_url() <> "/join/#{token}"
    end
  end

  defp generate_unsubscribe_url(%Brand{} = brand, creator_id) do
    token = Outreach.generate_unsubscribe_token(brand.id, creator_id)

    if use_brand_domains_in_outbound?() and not outbound_base_override?() do
      BrandRoutes.brand_url(brand, "/unsubscribe/#{token}")
    else
      outbound_base_url() <> "/unsubscribe/#{token}"
    end
  end

  defp creator_display_name(creator) do
    cond do
      creator.first_name && creator.first_name != "" -> creator.first_name
      creator.tiktok_username && creator.tiktok_username != "" -> creator.tiktok_username
      true -> "there"
    end
  end

  defp substitute_variables(nil, _variables), do: nil

  defp substitute_variables(content, variables) when is_binary(content) do
    Enum.reduce(variables, content, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", value || "")
    end)
  end

  # Convert relative URLs (starting with /) to absolute URLs
  # - `src` uses `asset_base_url` so email assets are always served from the app host
  # - `href` uses `link_base_url` so links keep brand-domain routing behavior
  defp absolutize_urls(content, link_base_url, asset_base_url) when is_binary(content) do
    content
    |> String.replace(~r/src=(["'])\/(?!\/)/, "src=\\1#{asset_base_url}/")
    |> String.replace(~r/href=(["'])\/(?!\/)/, "href=\\1#{link_base_url}/")
  end

  defp absolutize_urls(nil, _link_base_url, _asset_base_url), do: nil

  defp replace_lark_urls(content, join_url) when is_binary(content) do
    Regex.replace(@lark_url_pattern, content, join_url)
  end

  defp replace_lark_urls(nil, _join_url), do: nil

  # Convert HTML to plain text by stripping tags
  defp html_to_text(html) when is_binary(html) do
    html
    |> String.replace(~r/<br\s*\/?>/, "\n")
    |> String.replace(~r/<\/p>/, "\n\n")
    |> String.replace(~r/<\/div>/, "\n")
    |> String.replace(~r/<\/li>/, "\n")
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/&nbsp;/, " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp html_to_text(nil), do: ""

  defp brand_logo_url(%Brand{} = brand, asset_base_url) do
    logo_path =
      case brand.logo_url do
        "http://" <> _ = logo_url ->
          logo_url

        "https://" <> _ = logo_url ->
          logo_url

        _ ->
          Storage.public_url(brand.logo_url) ||
            "/images/brands/#{brand.slug}.png"
      end

    absolutize_url(logo_path, asset_base_url)
  end

  defp normalize_legacy_asset_hosts(content) when is_binary(content) do
    Enum.reduce(@legacy_asset_hosts, content, fn host, acc ->
      String.replace(acc, "#{host}/images/", "/images/")
    end)
  end

  defp normalize_legacy_asset_hosts(nil), do: nil

  defp normalize_logo_image_dimensions(content, logo_url) when is_binary(content) do
    escaped_logo_url = Regex.escape(logo_url)

    Regex.replace(
      ~r/(<img\b[^>]*\bsrc=(["'])#{escaped_logo_url}\2[^>]*?)\sheight=(["'])[^"']*\3([^>]*>)/i,
      content,
      "\\1\\4"
    )
  end

  defp normalize_logo_image_dimensions(nil, _logo_url), do: nil

  defp absolutize_url(url, base_url) when is_binary(url) do
    cond do
      String.starts_with?(url, "http://") or String.starts_with?(url, "https://") ->
        url

      String.starts_with?(url, "/") ->
        base_url <> url

      true ->
        base_url <> "/" <> url
    end
  end

  defp link_base_url(%Brand{} = brand) do
    if use_brand_domains_in_outbound?() and not outbound_base_override?() do
      BrandRoutes.brand_base_url(brand)
    else
      outbound_base_url() <> "/b/#{brand.slug}"
    end
  end

  defp asset_base_url do
    outbound_base_url()
  end

  defp outbound_base_url do
    case Application.get_env(:social_objects, :outbound_base_url) do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> SocialObjectsWeb.Endpoint.url()
    end
  end

  defp outbound_base_override? do
    case Application.get_env(:social_objects, :outbound_base_url) do
      url when is_binary(url) and url != "" -> true
      _ -> false
    end
  end

  defp use_brand_domains_in_outbound? do
    Application.get_env(:social_objects, :use_brand_domains_in_outbound, true)
  end
end
