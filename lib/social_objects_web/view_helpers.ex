defmodule SocialObjectsWeb.ViewHelpers do
  @moduledoc """
  Shared helper functions for LiveViews and Components.

  This module consolidates common functionality used across multiple
  LiveViews and Components to reduce code duplication and maintain
  consistency.

  ## Functions

  ### Product Helpers
  - `add_primary_image/1` - Adds primary image to product struct
  - `public_image_url/1` - Returns public URL for image (currently Shopify URLs)
  - `shopify_thumbnail_url/2` - Transforms Shopify URL to thumbnail size
  - `session_top_products/2` - Gets top N products from session with images

  ### Price Formatting
  - `format_price/1` - Formats price in cents to dollar string ($X.XX)
  - `format_cents_to_dollars/1` - Converts cents integer to dollars float
  - `convert_prices_to_cents/1` - Converts price params from dollars to cents

  ### Number Formatting
  - `format_number/1` - Formats numbers with thousand separators (1234 -> "1,234")

  ## Usage

  In LiveViews:
      import SocialObjectsWeb.ViewHelpers

  In Components:
      import SocialObjectsWeb.ViewHelpers
  """

  @doc """
  Adds the primary image to a product struct.

  Finds the image marked as primary, or falls back to the first image
  if no primary is set.

  ## Examples

      iex> product = %Product{product_images: [%{is_primary: true, path: "a.jpg"}]}
      iex> add_primary_image(product).primary_image.path
      "a.jpg"
  """
  def add_primary_image(product) do
    primary_image =
      product.product_images
      |> Enum.find(& &1.is_primary)
      |> case do
        nil -> List.first(product.product_images)
        image -> image
      end

    Map.put(product, :primary_image, primary_image)
  end

  @doc """
  Returns the public URL for an image path.

  Currently, images are stored in Shopify, so the path is already
  a full URL and is returned as-is.

  ## Examples

      iex> public_image_url("https://cdn.shopify.com/...")
      "https://cdn.shopify.com/..."
  """
  def public_image_url(path) do
    # Path is already a full Shopify URL
    path
  end

  @doc """
  Transforms a Shopify image URL to a thumbnail size.

  Shopify CDN supports URL-based image transformations by inserting
  size parameters before the file extension.

  ## Size Options

  - Atom: `:pico` (16x16), `:icon` (32x32), `:thumb` (50x50),
    `:small` (100x100), `:compact` (160x160), `:medium` (240x240),
    `:large` (480x480), `:grande` (600x600)
  - String: Custom dimensions like "80x80" or "120x120"

  ## Examples

      iex> shopify_thumbnail_url("https://cdn.shopify.com/.../image.jpg", :small)
      "https://cdn.shopify.com/.../image_small.jpg"

      iex> shopify_thumbnail_url("https://cdn.shopify.com/.../image.jpg", "80x80")
      "https://cdn.shopify.com/.../image_80x80.jpg"

      iex> shopify_thumbnail_url(nil, :small)
      nil
  """
  def shopify_thumbnail_url(nil, _size), do: nil

  def shopify_thumbnail_url(url, size) when is_binary(url) do
    # TikTok CDN URLs already have sizing built into the filename and are signed,
    # so return them unchanged to avoid breaking the URL
    if String.contains?(url, "ttcdn"), do: url, else: transform_shopify_url(url, size)
  end

  defp transform_shopify_url(url, size) do
    case Path.extname(url) do
      "" -> url
      ext -> "#{String.replace_suffix(url, ext, "")}_#{size}#{ext}"
    end
  end

  @doc """
  Gets the top N products from a session with their primary images.

  Returns a list of {product, primary_image} tuples, filtering out
  any products that don't have images.

  Defaults to showing up to 20 products for thumbnail previews.

  ## Examples

      iex> session_top_products(session)
      [{%Product{}, %ProductImage{}}, {%Product{}, %ProductImage{}}]

      iex> session_top_products(session, 10)
      [{%Product{}, %ProductImage{}}, ...]
  """
  def session_top_products(session, count \\ 20) do
    product_set_top_products(session, count)
  end

  def product_set_top_products(product_set, count \\ 20) do
    product_set.product_set_products
    |> Enum.take(count)
    |> Enum.map(fn psp ->
      primary_image =
        psp.product.product_images
        |> Enum.find(& &1.is_primary)
        |> case do
          nil -> List.first(psp.product.product_images)
          image -> image
        end

      {psp.product, primary_image}
    end)
    |> Enum.filter(fn {_product, image} -> image != nil end)
  end

  @doc """
  Formats a price in cents to a dollar string.

  ## Examples

      iex> format_price(1995)
      "$19.95"

      iex> format_price(nil)
      ""
  """
  def format_price(nil), do: ""

  def format_price(cents) when is_integer(cents) do
    dollars = div(cents, 100)
    cents_remainder = rem(cents, 100)
    "$#{dollars}.#{String.pad_leading(Integer.to_string(cents_remainder), 2, "0")}"
  end

  @doc """
  Formats GMV (in cents) with compact display for larger values.

  ## Examples

      iex> format_gmv(1234_56)
      "$1.2k"

      iex> format_gmv(99_00)
      "$99"
  """
  def format_gmv(nil), do: "$0"
  def format_gmv(0), do: "$0"

  def format_gmv(%Decimal{} = cents) do
    format_gmv(Decimal.to_integer(cents))
  end

  def format_gmv(cents) when is_integer(cents) do
    dollars = cents / 100

    if dollars >= 1000 do
      "$#{Float.round(dollars / 1000, 1)}k"
    else
      "$#{trunc(dollars)}"
    end
  end

  @doc """
  Converts cents (integer) to dollars (float).

  Used for displaying prices in form inputs where users enter dollar amounts.

  ## Examples

      iex> format_cents_to_dollars(1995)
      19.95

      iex> format_cents_to_dollars(nil)
      nil
  """
  def format_cents_to_dollars(nil), do: nil

  def format_cents_to_dollars(cents) when is_integer(cents) do
    cents / 100
  end

  @doc """
  Converts price fields from dollars to cents in form params.

  Handles both original_price_cents and sale_price_cents fields,
  converting dollar amounts (e.g., "19.95") to cents (1995).

  ## Examples

      iex> convert_prices_to_cents(%{"original_price_cents" => "19.95"})
      %{"original_price_cents" => 1995}
  """
  def convert_prices_to_cents(params) do
    params
    |> convert_price_field("original_price_cents")
    |> convert_price_field("sale_price_cents")
  end

  # Private helper functions for price conversion

  defp convert_price_field(params, field) do
    case Map.get(params, field) do
      nil ->
        params

      "" ->
        Map.put(params, field, nil)

      value when is_binary(value) ->
        parse_price_value(params, field, value)

      value when is_integer(value) ->
        params

      _ ->
        params
    end
  end

  defp parse_price_value(params, field, value) do
    case String.contains?(value, ".") do
      true -> convert_dollars_to_cents(params, field, value)
      false -> params
    end
  end

  defp convert_dollars_to_cents(params, field, value) do
    case Float.parse(value) do
      {dollars, _} -> Map.put(params, field, round(dollars * 100))
      :error -> params
    end
  end

  @doc """
  Formats a number with thousand separators.

  ## Examples

      iex> format_number(1234)
      "1,234"

      iex> format_number(1234567)
      "1,234,567"

      iex> format_number(nil)
      "0"
  """
  def format_number(nil), do: "0"

  def format_number(num) when is_integer(num) do
    num
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @doc """
  Extracts the numeric ID from a Shopify GID.

  Shopify GIDs are in the format "gid://shopify/Product/8772010639613".
  This function extracts just the numeric ID portion.

  ## Examples

      iex> extract_shopify_numeric_id("gid://shopify/Product/8772010639613")
      "8772010639613"

      iex> extract_shopify_numeric_id(nil)
      nil
  """
  def extract_shopify_numeric_id(nil), do: nil

  def extract_shopify_numeric_id(gid) when is_binary(gid) do
    case String.split(gid, "/") do
      [_, _, _, _, id] -> id
      _ -> nil
    end
  end

  @doc """
  Renders a template preview HTML suitable for an iframe srcdoc.

  For email templates, returns the HTML body directly.
  For page templates, injects the consent form and wraps with minimal styles.
  """
  def template_preview_html(%{type: "page"} = template) do
    template_preview_html(template, SocialObjects.Settings.app_name())
  end

  def template_preview_html(template) do
    template.html_body
  end

  def template_preview_html(%{type: "page"} = template, brand_name) do
    form_config = template.form_config || %{}
    button_text = form_config["button_text"] || "JOIN THE PROGRAM"
    email_label = form_config["email_label"] || "Email"
    phone_label = form_config["phone_label"] || "Phone Number"
    phone_placeholder = form_config["phone_placeholder"] || "(555) 123-4567"
    brand_name = brand_name || SocialObjects.Settings.app_name()

    # Static form HTML with inline styles (matches the inline-styled template)
    form_html = """
    <form style="margin-top: 20px;">
      <div style="margin-bottom: 20px;">
        <label style="display: block; font-weight: bold; margin-bottom: 8px; font-size: 14px; color: #2E4042;">#{email_label}</label>
        <input type="email" value="creator@example.com" readonly style="width: 100%; padding: 12px 16px; font-family: Georgia, serif; font-size: 16px; border: 1px solid #ccc; border-radius: 4px; background: #f5f5f5; color: #666;" />
      </div>
      <div style="margin-bottom: 20px;">
        <label style="display: block; font-weight: bold; margin-bottom: 8px; font-size: 14px; color: #2E4042;">#{phone_label}</label>
        <input type="tel" placeholder="#{phone_placeholder}" style="width: 100%; padding: 12px 16px; font-family: Georgia, serif; font-size: 16px; border: 1px solid #ccc; border-radius: 4px; background: #fff; color: #2E4042;" />
      </div>
      <p style="font-size: 12px; color: #888; line-height: 1.5; margin: 16px 0 24px;">
        By clicking "#{button_text}", you consent to receive SMS messages from #{brand_name}
        at the phone number provided. Message frequency varies. Msg &amp; data rates may apply.
        Reply STOP to unsubscribe.
      </p>
      <button type="button" style="width: 100%; padding: 16px 32px; font-family: Georgia, serif; font-size: 15px; letter-spacing: 1px; background: #2E4042; color: #fff; border: none; cursor: pointer; border-radius: 4px;">#{button_text}</button>
    </form>
    """

    html_with_form =
      Regex.replace(
        ~r/<div[^>]*data-form-type="consent"[^>]*>[\s\S]*?<\/div>/i,
        template.html_body || "",
        form_html
      )

    # Wrap with minimal reset styles for iframe rendering
    # Disable link clicks in preview to prevent navigation to unsubstituted template URLs
    """
    <!DOCTYPE html>
    <html>
    <head>
      <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        a { pointer-events: none; cursor: default; }
      </style>
    </head>
    <body>#{html_with_form}</body>
    </html>
    """
  end

  def template_preview_html(template, _brand_name) do
    template.html_body
  end
end
