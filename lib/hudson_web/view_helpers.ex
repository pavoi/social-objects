defmodule HudsonWeb.ViewHelpers do
  @moduledoc """
  Shared helper functions for LiveViews and Components.

  This module consolidates common functionality used across multiple
  LiveViews and Components to reduce code duplication and maintain
  consistency.

  ## Functions

  ### Product Helpers
  - `add_primary_image/1` - Adds primary image to product struct
  - `public_image_url/1` - Returns public URL for image (currently Shopify URLs)

  ### Price Formatting
  - `format_price/1` - Formats price in cents to dollar string ($X.XX)
  - `format_cents_to_dollars/1` - Converts cents integer to dollars float
  - `convert_prices_to_cents/1` - Converts price params from dollars to cents

  ## Usage

  In LiveViews:
      import HudsonWeb.ViewHelpers

  In Components:
      import HudsonWeb.ViewHelpers
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
end
