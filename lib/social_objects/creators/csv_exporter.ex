defmodule SocialObjects.Creators.CsvExporter do
  @moduledoc """
  Generates CSV content from creator structs for export.

  Exports stable, non-stale data columns useful for external workflows
  (outreach tools, spreadsheets, etc.).
  """

  @headers [
    "TikTok Username",
    "TikTok Profile URL",
    "Email",
    "Phone",
    "Phone Verified",
    "First Name",
    "Last Name",
    "Address Line 1",
    "Address Line 2",
    "City",
    "State",
    "Zipcode",
    "Country",
    "Follower Count",
    "Total GMV ($)",
    "Avg Video Views",
    "Video Count",
    "Live Count",
    "Sample Count",
    "Total Commission ($)",
    "Tags",
    "Email Opted Out",
    "Outreach Sent At",
    "Added At",
    "Last Enriched At"
  ]

  @doc """
  Generates CSV content from a list of creators.

  Returns a string containing the full CSV with headers.
  """
  def generate(creators) when is_list(creators) do
    rows = [headers_row() | Enum.map(creators, &creator_row/1)]
    Enum.join(rows, "\r\n")
  end

  @doc """
  Returns the filename for the export.
  """
  def filename do
    date = Date.utc_today() |> Date.to_iso8601()
    "creators_export_#{date}.csv"
  end

  defp headers_row do
    Enum.map_join(@headers, ",", &escape_field/1)
  end

  defp creator_row(creator) do
    [
      creator.tiktok_username,
      creator.tiktok_profile_url,
      creator.email,
      creator.phone,
      format_boolean(creator.phone_verified),
      creator.first_name,
      creator.last_name,
      creator.address_line_1,
      creator.address_line_2,
      creator.city,
      creator.state,
      creator.zipcode,
      creator.country,
      creator.follower_count,
      format_cents(creator.total_gmv_cents),
      creator.avg_video_views,
      Map.get(creator, :video_count, 0),
      creator.live_count,
      Map.get(creator, :sample_count, 0),
      format_cents(Map.get(creator, :total_commission_cents, 0)),
      format_tags(Map.get(creator, :creator_tags, [])),
      format_boolean(creator.email_opted_out),
      format_datetime(creator.outreach_sent_at),
      format_datetime(creator.inserted_at),
      format_datetime(creator.last_enriched_at)
    ]
    |> Enum.map_join(",", &escape_field/1)
  end

  defp escape_field(nil), do: ""

  defp escape_field(value) when is_binary(value) do
    if needs_escaping?(value) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end

  defp escape_field(value) when is_integer(value), do: Integer.to_string(value)
  defp escape_field(value) when is_float(value), do: Float.to_string(value)
  defp escape_field(value), do: escape_field(to_string(value))

  defp needs_escaping?(value) do
    String.contains?(value, [",", "\"", "\n", "\r"])
  end

  defp format_boolean(nil), do: ""
  defp format_boolean(true), do: "Yes"
  defp format_boolean(false), do: "No"

  defp format_cents(nil), do: ""

  defp format_cents(cents) when is_integer(cents) do
    dollars = cents / 100
    :erlang.float_to_binary(dollars, decimals: 2)
  end

  defp format_cents(%Decimal{} = cents) do
    cents
    |> Decimal.div(100)
    |> Decimal.round(2)
    |> Decimal.to_string()
  end

  defp format_datetime(nil), do: ""

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_datetime(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp format_tags(nil), do: ""
  defp format_tags([]), do: ""
  defp format_tags(tags) when is_list(tags), do: Enum.map_join(tags, ";", & &1.name)
end
