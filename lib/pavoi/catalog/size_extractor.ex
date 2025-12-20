defmodule Pavoi.Catalog.SizeExtractor do
  @moduledoc """
  Extracts and normalizes size information from various sources.

  ## Extraction Priority
  1. Shopify selected_options (keys: Size, Ring Size, Length, Diameter)
  2. TikTok sales_attributes
  3. SKU pattern parsing
  4. Product/variant name regex

  ## Size Types
  - :ring - Ring sizes (4-11, including half sizes)
  - :length - Bracelet/necklace lengths in inches (6.5", 7", 16", 18")
  - :diameter - Hoop/stone sizes in mm (3mm, 15mm, 20mm)
  - :apparel - Clothing sizes (S, M, L, XL, X-Small, etc.)
  """

  @size_option_keys [
    "Size",
    "Ring Size",
    "Length",
    "Diameter",
    "Item Display Length",
    "Pearl Size"
  ]

  # SKU patterns:
  # -Y5, -W7, -R10 = color letter + size number at end
  # -6.5Yv2, -7Wv2 = size + color + version
  # -FCHA-Y5 = style-color+size
  @sku_patterns [
    # Pattern: -<letter><number> at end (e.g., -Y5, -W7, -R10)
    ~r/-[A-Z](\d+(?:\.\d+)?)\z/i,
    # Pattern: -<style>-<letter><number> at end (e.g., -FCHA-Y5)
    ~r/-[A-Z]+-[A-Z](\d+(?:\.\d+)?)\z/i,
    # Pattern: -<number><letter>v<version> (e.g., -6.5Yv2, -7Wv2)
    ~r/-(\d+(?:\.\d+)?)[A-Z]v\d+\z/i,
    # Pattern: just -<number> at end (e.g., -7, -6.5)
    ~r/-(\d+(?:\.\d+)?)\z/
  ]

  # Name patterns for mm sizes
  @name_mm_pattern ~r/(\d+(?:\.\d+)?)\s*mm/i
  # Name patterns for inch sizes
  @name_inch_pattern ~r/(\d+(?:\.\d+)?)\s*(?:"|inch(?:es)?|in\b)/i

  # Apparel size normalization map
  @apparel_sizes %{
    "xs" => "XS",
    "x-small" => "XS",
    "xsmall" => "XS",
    "extra small" => "XS",
    "xx-small" => "XXS",
    "xxsmall" => "XXS",
    "s" => "S",
    "small" => "S",
    "sm" => "S",
    "m" => "M",
    "medium" => "M",
    "med" => "M",
    "l" => "L",
    "large" => "L",
    "lg" => "L",
    "xl" => "XL",
    "x-large" => "XL",
    "xlarge" => "XL",
    "extra large" => "XL",
    "xxl" => "XXL",
    "2xl" => "XXL",
    "xx-large" => "XXL",
    "2x" => "2X",
    "3x" => "3X",
    "4x" => "4X"
  }

  @doc """
  Extracts size from all available sources with priority fallbacks.

  ## Options
  - `:selected_options` - Map of Shopify variant options (e.g., %{"Size" => "7"})
  - `:tiktok_attributes` - List of TikTok sales_attributes
  - `:sku` - Product/variant SKU for pattern matching
  - `:name` - Product/variant name for regex extraction
  - `:product_name` - Product name for fallback regex extraction

  ## Returns
  `{size, size_type, source}` or `{nil, nil, nil}` if no size found.

  ## Examples

      iex> extract_size(selected_options: %{"Ring Size" => "7"})
      {"7", :ring, :shopify_options}

      iex> extract_size(sku: "2508-R03-Y5")
      {"5", :ring, :sku}

      iex> extract_size(name: "3.5mm Lightweight Hoop")
      {"3.5mm", :diameter, :name}
  """
  def extract_size(opts) do
    selected_options = Keyword.get(opts, :selected_options, %{})
    tiktok_attributes = Keyword.get(opts, :tiktok_attributes, [])
    sku = Keyword.get(opts, :sku)
    name = Keyword.get(opts, :name)
    product_name = Keyword.get(opts, :product_name)

    # Try each source in priority order
    extract_from_shopify_options(selected_options)
    |> or_try(fn -> extract_from_tiktok_attributes(tiktok_attributes) end)
    |> or_try(fn -> extract_from_sku(sku) end)
    |> or_try(fn -> extract_from_name(name) end)
    |> or_try(fn -> extract_from_name(product_name) end)
    |> normalize_result()
  end

  defp extract_from_shopify_options(options) when is_map(options) and map_size(options) > 0 do
    Enum.find_value(@size_option_keys, fn key ->
      case Map.get(options, key) do
        nil -> nil
        "" -> nil
        value -> {value, detect_size_type(key, value), :shopify_options}
      end
    end)
  end

  defp extract_from_shopify_options(_), do: nil

  defp extract_from_tiktok_attributes(attributes)
       when is_list(attributes) and length(attributes) > 0 do
    # TikTok sales_attributes structure: [%{"attribute_name" => "Size", "value_name" => "7"}, ...]
    # Also handles alternative keys: [%{"name" => "Size", "value" => "7"}, ...]
    Enum.find_value(attributes, &extract_size_from_tiktok_attr/1)
  end

  defp extract_size_from_tiktok_attr(attr) do
    attr_name = attr["attribute_name"] || attr["name"] || ""
    value = attr["value_name"] || attr["value"] || ""

    if size_attribute?(attr_name) and value != "" do
      {value, detect_size_type(attr_name, value), :tiktok_attributes}
    end
  end

  defp extract_from_tiktok_attributes(_), do: nil

  defp extract_from_sku(nil), do: nil
  defp extract_from_sku(""), do: nil

  defp extract_from_sku(sku) do
    Enum.find_value(@sku_patterns, fn pattern ->
      case Regex.run(pattern, sku) do
        [_, size] -> {size, :ring, :sku}
        _ -> nil
      end
    end)
  end

  defp extract_from_name(nil), do: nil
  defp extract_from_name(""), do: nil

  defp extract_from_name(name) do
    cond do
      match = Regex.run(@name_mm_pattern, name) ->
        [_, size] = match
        {"#{size}mm", :diameter, :name}

      match = Regex.run(@name_inch_pattern, name) ->
        [_, size] = match
        {"#{size}\"", :length, :name}

      true ->
        nil
    end
  end

  defp size_attribute?(name) when is_binary(name) do
    downcased = String.downcase(name)
    Enum.any?(["size", "ring", "length", "diameter"], &String.contains?(downcased, &1))
  end

  defp size_attribute?(_), do: false

  defp detect_size_type(key, value) do
    key_lower = String.downcase(to_string(key))
    value_str = to_string(value)

    detect_type_from_key(key_lower) || detect_type_from_value(value_str)
  end

  defp detect_type_from_key(key) do
    cond do
      String.contains?(key, "ring") -> :ring
      String.contains?(key, "length") -> :length
      String.contains?(key, "diameter") -> :diameter
      true -> nil
    end
  end

  defp detect_type_from_value(value) do
    value_lower = String.downcase(value)

    cond do
      String.contains?(value_lower, "mm") -> :diameter
      String.contains?(value_lower, "\"") or String.contains?(value_lower, "inch") -> :length
      Map.has_key?(@apparel_sizes, value_lower) -> :apparel
      numeric_size?(value) -> :ring
      true -> nil
    end
  end

  defp numeric_size?(value) do
    String.match?(to_string(value), ~r/^\d+(?:\.\d+)?$/)
  end

  defp or_try(nil, func), do: func.()
  defp or_try(result, _func), do: result

  defp normalize_result({size, type, source}) do
    {normalize_size(size, type), type, source}
  end

  defp normalize_result(nil), do: {nil, nil, nil}

  defp normalize_size(size, :apparel) do
    key = String.downcase(String.trim(to_string(size)))
    Map.get(@apparel_sizes, key, size)
  end

  defp normalize_size(size, :ring) do
    # Handle SKU encoding where 65 = 6.5, 75 = 7.5, etc.
    trimmed = String.trim(to_string(size))

    case Integer.parse(trimmed) do
      {num, ""} when num >= 45 and num <= 115 and rem(num, 10) == 5 ->
        # Two-digit ring size ending in 5 is a half-size (65 -> 6.5)
        "#{div(num, 10)}.5"

      _ ->
        trimmed
    end
  end

  defp normalize_size(size, _type), do: String.trim(to_string(size))

  @doc """
  Computes size_range from a list of variant structs or maps with :size field.

  Returns a human-readable string like "5-9" or "16\"-20\"" or nil if no sizes.

  ## Examples

      iex> compute_size_range([%{size: "5"}, %{size: "7"}, %{size: "9"}])
      "5-9"

      iex> compute_size_range([%{size: "3mm"}, %{size: "15mm"}, %{size: "30mm"}])
      "3mm-30mm"

      iex> compute_size_range([%{size: nil}])
      nil
  """
  def compute_size_range(variants) when is_list(variants) do
    sizes =
      variants
      |> Enum.map(&get_size/1)
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.uniq()

    case sizes do
      [] -> nil
      [single] -> single
      multiple -> format_size_range(multiple)
    end
  end

  def compute_size_range(_), do: nil

  defp get_size(%{size: size}), do: size
  defp get_size(%{"size" => size}), do: size
  defp get_size(_), do: nil

  defp format_size_range(sizes) do
    # Try to parse as numeric and create range
    {numeric_sizes, suffix} = extract_numeric_sizes(sizes)

    case numeric_sizes do
      [] ->
        # Non-numeric sizes, just list them
        Enum.sort(sizes) |> Enum.join(", ")

      nums ->
        min_val = Enum.min(nums)
        max_val = Enum.max(nums)
        "#{format_number(min_val)}#{suffix}-#{format_number(max_val)}#{suffix}"
    end
  end

  defp extract_numeric_sizes(sizes) do
    # Detect common suffix (mm, ", etc.)
    suffix = detect_common_suffix(sizes)

    numeric_sizes =
      sizes
      |> Enum.map(&parse_numeric_size/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    {numeric_sizes, suffix}
  end

  defp parse_numeric_size(size) do
    # Remove common suffixes and parse the number
    cleaned = String.replace(to_string(size), ~r/(mm|"|in|inches?)$/i, "")

    case Float.parse(String.trim(cleaned)) do
      {num, _} -> num
      :error -> nil
    end
  end

  defp detect_common_suffix(sizes) do
    first_size = List.first(sizes) |> to_string()

    cond do
      String.contains?(first_size, "mm") -> "mm"
      String.contains?(first_size, "\"") -> "\""
      String.contains?(first_size, "inch") -> "\""
      true -> ""
    end
  end

  defp format_number(num) when is_float(num) do
    if num == Float.floor(num) do
      trunc(num)
    else
      num
    end
  end

  defp format_number(num), do: num
end
