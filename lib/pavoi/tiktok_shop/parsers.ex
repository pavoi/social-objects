defmodule Pavoi.TiktokShop.Parsers do
  @moduledoc """
  Shared parsing functions for TikTok Shop API responses.

  Used by analytics sync workers and mix tasks to parse common data formats
  from the TikTok Shop Analytics API.
  """

  @doc """
  Parses a monetary amount string to cents.

  Handles various input formats:
  - nil -> nil (or 0 with `default: 0`)
  - %{"amount" => "15110.03"} -> 1511003
  - "15110.03" -> 1511003
  - 15110.03 -> 1511003

  ## Options

  - `:default` - Value to return for nil input (default: nil)

  ## Examples

      iex> parse_gmv_cents("15110.03")
      1511003

      iex> parse_gmv_cents(%{"amount" => "99.99"})
      9999

      iex> parse_gmv_cents(nil)
      nil

      iex> parse_gmv_cents(nil, default: 0)
      0
  """
  def parse_gmv_cents(value, opts \\ [])
  def parse_gmv_cents(nil, opts), do: Keyword.get(opts, :default, nil)

  def parse_gmv_cents(%{"amount" => amount}, opts) do
    parse_gmv_cents(amount, opts)
  end

  def parse_gmv_cents(amount, _opts) when is_binary(amount) do
    case Float.parse(amount) do
      {value, _} -> round(value * 100)
      :error -> nil
    end
  end

  def parse_gmv_cents(amount, _opts) when is_number(amount) do
    round(amount * 100)
  end

  @doc """
  Parses a GMV amount for comparison/sorting (returns float, not cents).

  ## Examples

      iex> parse_gmv_amount(%{"amount" => "15110.03"})
      15110.03

      iex> parse_gmv_amount(nil)
      0
  """
  def parse_gmv_amount(nil), do: 0

  def parse_gmv_amount(%{"amount" => amount}) do
    case Float.parse(amount || "0") do
      {value, _} -> value
      :error -> 0
    end
  end

  def parse_gmv_amount(_), do: 0

  @doc """
  Parses a percentage string to a Decimal.

  Handles various formats:
  - "3.58%" -> Decimal(3.58)
  - "0.0454" (decimal < 1) -> Decimal(4.54) (auto-converts to percentage)
  - 3.58 -> Decimal(3.58)

  ## Examples

      iex> parse_percentage("3.58%")
      #Decimal<3.58>

      iex> parse_percentage("0.0454")
      #Decimal<4.54>

      iex> parse_percentage(nil)
      nil
  """
  def parse_percentage(nil), do: nil

  def parse_percentage(value) when is_binary(value) do
    cleaned = value |> String.replace("%", "") |> String.trim()

    case Float.parse(cleaned) do
      {num, _} ->
        # If value looks like a decimal (< 1) and wasn't a percentage string,
        # convert to percentage format
        final = if num < 1 && !String.contains?(value, "%"), do: num * 100, else: num
        Decimal.from_float(final)

      :error ->
        nil
    end
  end

  def parse_percentage(value) when is_number(value) do
    # Assume decimal format for numbers, convert to percentage if < 1
    final = if value < 1, do: value * 100, else: value
    Decimal.from_float(final * 1.0)
  end

  @doc """
  Parses a value to an integer.

  ## Options

  - `:default` - Value to return for nil input (default: nil)

  ## Examples

      iex> parse_integer("123")
      123

      iex> parse_integer(123.7)
      124

      iex> parse_integer(nil)
      nil

      iex> parse_integer(nil, default: 0)
      0
  """
  def parse_integer(value, opts \\ [])
  def parse_integer(nil, opts), do: Keyword.get(opts, :default, nil)

  def parse_integer(value, _opts) when is_binary(value) do
    case Integer.parse(value) do
      {num, _} -> num
      :error -> nil
    end
  end

  def parse_integer(value, _opts) when is_integer(value), do: value
  def parse_integer(value, _opts) when is_float(value), do: round(value)

  @doc """
  Parses a Unix timestamp to DateTime.

  ## Examples

      iex> parse_unix_timestamp(1770311224)
      ~U[2026-02-05 12:00:24Z]

      iex> parse_unix_timestamp("1770311224")
      ~U[2026-02-05 12:00:24Z]

      iex> parse_unix_timestamp(nil)
      nil
  """
  def parse_unix_timestamp(nil), do: nil

  def parse_unix_timestamp(timestamp) when is_integer(timestamp) do
    DateTime.from_unix!(timestamp)
  end

  def parse_unix_timestamp(timestamp) when is_binary(timestamp) do
    case Integer.parse(timestamp) do
      {ts, _} -> DateTime.from_unix!(ts)
      :error -> nil
    end
  end

  @doc """
  Parses a TikTok video post time string to DateTime.

  Handles the format "2025-12-28 12:34:20".

  ## Examples

      iex> parse_video_post_time("2025-12-28 12:34:20")
      ~U[2025-12-28 12:34:20Z]

      iex> parse_video_post_time(nil)
      nil
  """
  def parse_video_post_time(nil), do: nil

  def parse_video_post_time(datetime_str) when is_binary(datetime_str) do
    case NaiveDateTime.from_iso8601(String.replace(datetime_str, " ", "T")) do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
      {:error, _} -> nil
    end
  end

  def parse_video_post_time(_), do: nil

  @doc """
  Parses hashtags from API response.

  ## Examples

      iex> parse_hash_tags(["tag1", "tag2"])
      ["tag1", "tag2"]

      iex> parse_hash_tags(nil)
      []
  """
  def parse_hash_tags(nil), do: []
  def parse_hash_tags(tags) when is_list(tags), do: tags
  def parse_hash_tags(_), do: []

  @doc """
  Parses a list of product performance data from TikTok API response.

  Each product map should have "id", "name", "sales", and "traffic" keys.
  Returns a list of maps sorted by GMV descending.

  ## Examples

      iex> parse_product_performance([%{"id" => "123", "name" => "Widget", "sales" => %{}, "traffic" => %{}}])
      [%{"product_id" => "123", "product_name" => "Widget", "gmv_cents" => nil, ...}]
  """
  def parse_product_performance(products) when is_list(products) do
    products
    |> Enum.map(fn product ->
      sales = product["sales"] || %{}
      traffic = product["traffic"] || %{}

      %{
        "product_id" => product["id"],
        "product_name" => product["name"],
        "gmv_cents" => parse_gmv_cents(sales["direct_gmv"]),
        "items_sold" => parse_integer(sales["items_sold"]),
        "customers" => parse_integer(sales["customers"]),
        "orders" => parse_integer(sales["sku_orders"]),
        "impressions" => parse_integer(traffic["product_impressions"]),
        "clicks" => parse_integer(traffic["add_to_cart_count"])
      }
    end)
    |> Enum.sort_by(& &1["gmv_cents"], :desc)
  end

  def parse_product_performance(_), do: []
end
