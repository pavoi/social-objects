defmodule Pavoi.Shopify.GID do
  @moduledoc """
  Utilities for working with Shopify Global IDs (GIDs).

  Shopify's GraphQL API uses GIDs in the format:
  `gid://shopify/ResourceType/12345`

  This module provides functions for extracting and working with these IDs.
  """

  @doc """
  Extracts the numeric ID from a Shopify GID for display purposes.

  ## Examples

      iex> Pavoi.Shopify.GID.display_id("gid://shopify/Product/8034117484797")
      "8034117484797"

      iex> Pavoi.Shopify.GID.display_id("gid://shopify/ProductVariant/12345")
      "12345"

      iex> Pavoi.Shopify.GID.display_id(nil)
      nil

      iex> Pavoi.Shopify.GID.display_id("12345")
      "12345"
  """
  def display_id(nil), do: nil

  def display_id(gid) when is_binary(gid) do
    case String.split(gid, "/") do
      [_, _, _, _, numeric_id] -> numeric_id
      _ -> gid
    end
  end

  @doc """
  Constructs a Shopify GID from a resource type and numeric ID.

  Useful for future API calls that require the full GID format.

  ## Examples

      iex> Pavoi.Shopify.GID.to_gid("Product", "8034117484797")
      "gid://shopify/Product/8034117484797"

      iex> Pavoi.Shopify.GID.to_gid("ProductVariant", "12345")
      "gid://shopify/ProductVariant/12345"
  """
  def to_gid(resource_type, numeric_id) when is_binary(resource_type) and is_binary(numeric_id) do
    "gid://shopify/#{resource_type}/#{numeric_id}"
  end

  def to_gid(resource_type, numeric_id)
      when is_binary(resource_type) and is_integer(numeric_id) do
    to_gid(resource_type, Integer.to_string(numeric_id))
  end
end
