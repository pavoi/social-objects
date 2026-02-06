# credo:disable-for-this-file Credo.Check.Refactor.Nesting
# credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
defmodule Pavoi.Workers.CreatorImportWorker do
  @moduledoc """
  Oban worker that imports creator data from CSV files.

  Supports importing from multiple CSV sources:
  - Euka contact data (email, phone, address)
  - Phone Numbers raw data (first/last name, phone)
  - Sample orders data (buyer info, products received)
  - Video performance data
  - Refunnel performance metrics

  ## Usage

  Queue an import job:

      %{source: "euka", file_path: "/path/to/file.csv"}
      |> Pavoi.Workers.CreatorImportWorker.new()
      |> Oban.insert()

  ## Import Sources

  - `"euka"` - Creator email/phone/address from Euka export
  - `"phone_numbers"` - Phone numbers raw data with names
  - `"samples"` - Free sample order data
  - `"videos"` - Video performance data
  - `"refunnel"` - Creator performance metrics from Refunnel
  """

  use Oban.Worker,
    queue: :creators,
    max_attempts: 3,
    unique: [period: 300, states: [:available, :scheduled, :executing]]

  require Logger
  alias Pavoi.Creators
  alias Pavoi.Settings

  # Define CSV parser
  NimbleCSV.define(CreatorCSV, separator: ",", escape: "\"")

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source" => source, "file_path" => file_path} = args}) do
    brand_id = args["brand_id"]
    Logger.info("Starting creator import from #{source}: #{file_path}")

    Phoenix.PubSub.broadcast(Pavoi.PubSub, "creators:import", {:import_started, source})

    result =
      case source do
        "euka" -> import_euka_data(file_path)
        "phone_numbers" -> import_phone_numbers(file_path)
        "samples" -> import_samples_data(file_path, brand_id)
        "videos" -> import_videos_data(file_path, brand_id)
        "refunnel" -> import_refunnel_data(file_path, brand_id)
        _ -> {:error, "Unknown source: #{source}"}
      end

    case result do
      {:ok, counts} ->
        Logger.info("✅ Import completed: #{inspect(counts)}")

        # Update timestamp for video imports
        if source == "videos" do
          Settings.update_videos_last_import_at(brand_id)
        end

        Phoenix.PubSub.broadcast(
          Pavoi.PubSub,
          "creators:import",
          {:import_completed, source, counts}
        )

        :ok

      {:error, reason} ->
        Logger.error("Import failed: #{inspect(reason)}")

        Phoenix.PubSub.broadcast(
          Pavoi.PubSub,
          "creators:import",
          {:import_failed, source, reason}
        )

        {:error, reason}
    end
  end

  @doc """
  Imports creator contact data from Euka CSV export.

  Expected columns: handle, email, phone, address
  """
  def import_euka_data(file_path) do
    {headers, rows} = parse_csv_with_headers(file_path)

    rows
    |> Stream.with_index(1)
    |> Enum.reduce(%{created: 0, updated: 0, errors: 0}, fn {row, index}, acc ->
      row = zip_headers(headers, row)

      case process_euka_row(row) do
        {:ok, :created} ->
          %{acc | created: acc.created + 1}

        {:ok, :updated} ->
          %{acc | updated: acc.updated + 1}

        {:error, reason} ->
          Logger.warning("Row #{index} failed: #{inspect(reason)}")
          %{acc | errors: acc.errors + 1}
      end
    end)
    |> then(&{:ok, &1})
  end

  defp process_euka_row(row) do
    username = row["handle"] || row["Handle"]

    if blank?(username) do
      {:error, "Missing username"}
    else
      attrs = %{
        tiktok_username: username,
        email: blank_to_nil(row["email"] || row["Email"]),
        phone: Creators.normalize_phone(row["phone"] || row["Phone"]),
        phone_verified: !phone_masked?(row["phone"] || row["Phone"])
      }

      # Parse address if present
      attrs = maybe_parse_address(attrs, row["address"] || row["Address"])

      case Creators.get_creator_by_username(username) do
        nil ->
          case Creators.create_creator(attrs) do
            {:ok, _} -> {:ok, :created}
            {:error, changeset} -> {:error, changeset.errors}
          end

        _existing ->
          case Creators.upsert_creator(attrs) do
            {:ok, _} -> {:ok, :updated}
            {:error, changeset} -> {:error, changeset.errors}
          end
      end
    end
  end

  @doc """
  Imports phone numbers and names from raw data CSV.

  Expected columns: Username, Recipient, First Name, Last Name, Phone #
  """
  def import_phone_numbers(file_path) do
    {headers, rows} = parse_csv_with_headers(file_path)

    rows
    |> Stream.with_index(1)
    |> Enum.reduce(%{created: 0, updated: 0, errors: 0}, fn {row, index}, acc ->
      row = zip_headers(headers, row)

      case process_phone_row(row) do
        {:ok, :created} ->
          %{acc | created: acc.created + 1}

        {:ok, :updated} ->
          %{acc | updated: acc.updated + 1}

        {:error, _reason} ->
          if rem(index, 1000) == 0 do
            Logger.debug("Processed #{index} phone rows")
          end

          %{acc | errors: acc.errors + 1}
      end
    end)
    |> then(&{:ok, &1})
  end

  defp process_phone_row(row) do
    username = row["Username"]

    if blank?(username) do
      {:error, "Missing username"}
    else
      phone = row["Phone #"] || row["Phone"]

      attrs = %{
        tiktok_username: username,
        first_name: blank_to_nil(row["First Name"]),
        last_name: blank_to_nil(row["Last Name"]),
        phone: Creators.normalize_phone(phone),
        phone_verified: !phone_masked?(phone)
      }

      case Creators.upsert_creator(attrs) do
        {:ok, creator} ->
          if creator.inserted_at == creator.updated_at do
            {:ok, :created}
          else
            {:ok, :updated}
          end

        {:error, changeset} ->
          {:error, changeset.errors}
      end
    end
  end

  @doc """
  Imports sample order data.

  Expected columns include: Buyer Username, Recipient, Phone #,
  Product Name, Variation, Order ID, SKU ID, timestamps, etc.
  """
  def import_samples_data(_file_path, nil),
    do: {:error, "brand_id is required for sample imports"}

  def import_samples_data(file_path, brand_id) do
    # Skip first two rows (headers + description row)
    {headers, rows} = parse_csv_with_headers(file_path, skip_rows: 1)

    rows
    |> Stream.with_index(1)
    |> Enum.reduce(%{creators: 0, samples: 0, errors: 0}, fn {row, index}, acc ->
      row = zip_headers(headers, row)

      case process_sample_row(row, brand_id) do
        {:ok, result} ->
          acc
          |> Map.update!(:creators, &(&1 + (result[:creator_created] || 0)))
          |> Map.update!(:samples, &(&1 + 1))

        {:error, _reason} ->
          if rem(index, 1000) == 0 do
            Logger.debug("Processed #{index} sample rows")
          end

          %{acc | errors: acc.errors + 1}
      end
    end)
    |> then(&{:ok, &1})
  end

  defp process_sample_row(row, brand_id) do
    username = row["Buyer Username"]

    if blank?(username) do
      {:error, "Missing username"}
    else
      # First, ensure creator exists
      creator_result =
        case Creators.get_creator_by_username(username) do
          nil ->
            phone = row["Phone #"]

            Creators.create_creator(%{
              tiktok_username: username,
              phone: Creators.normalize_phone(phone),
              phone_verified: !phone_masked?(phone),
              address_line_1: blank_to_nil(row["Address Line 1"]),
              address_line_2: blank_to_nil(row["Address Line 2"]),
              city: blank_to_nil(row["City"]),
              state: blank_to_nil(row["State"]),
              zipcode: blank_to_nil(row["Zipcode"]),
              country: row["Country"] || "US"
            })
            |> case do
              {:ok, creator} -> {:ok, creator, true}
              error -> error
            end

          existing ->
            {:ok, existing, false}
        end

      case creator_result do
        {:ok, creator, created?} ->
          # Associate creator with brand
          Creators.add_creator_to_brand(creator.id, brand_id)

          # Create sample record
          sample_attrs = %{
            creator_id: creator.id,
            brand_id: brand_id,
            tiktok_order_id: blank_to_nil(row["Order ID"]),
            tiktok_sku_id: blank_to_nil(row["SKU ID"]),
            product_name: blank_to_nil(row["Product Name"]),
            variation: blank_to_nil(row["Variation"]),
            quantity: parse_int(row["Quantity"], 1),
            ordered_at: parse_datetime(row["Created Time"]),
            shipped_at: parse_datetime(row["Shipped Time"]),
            delivered_at: parse_datetime(row["Delivered Time"]),
            status: map_order_status(row["Order Status"])
          }

          case Creators.create_creator_sample(sample_attrs) do
            {:ok, _sample} ->
              {:ok, %{creator_created: if(created?, do: 1, else: 0)}}

            {:error, changeset} ->
              # Likely duplicate, that's okay
              if has_unique_constraint_error?(changeset) do
                {:ok, %{creator_created: 0}}
              else
                {:error, changeset.errors}
              end
          end

        {:error, changeset} ->
          {:error, changeset.errors}
      end
    end
  end

  @doc """
  Imports video performance data.

  Expected columns: Video name, Video link, Video post date, Creator username,
  GMV, Affiliate items sold, impressions, likes, comments, etc.
  """
  def import_videos_data(file_path, brand_id) do
    {headers, rows} = parse_csv_with_headers(file_path)

    rows
    |> Stream.with_index(1)
    |> Enum.reduce(%{creators: 0, videos: 0, errors: 0}, fn {row, index}, acc ->
      row = zip_headers(headers, row)

      case process_video_row(row, brand_id) do
        {:ok, result} ->
          acc
          |> Map.update!(:creators, &(&1 + (result[:creator_created] || 0)))
          |> Map.update!(:videos, &(&1 + 1))

        {:error, _reason} ->
          if rem(index, 5000) == 0 do
            Logger.debug("Processed #{index} video rows")
          end

          %{acc | errors: acc.errors + 1}
      end
    end)
    |> then(&{:ok, &1})
  end

  defp process_video_row(row, brand_id) do
    username = row["Creator username"]
    video_url = row["Video link"]

    if blank?(username) || blank?(video_url) do
      {:error, "Missing username or video URL"}
    else
      # Extract video ID from URL
      video_id = extract_video_id(video_url)

      if blank?(video_id) do
        {:error, "Could not extract video ID"}
      else
        # First, ensure creator exists
        creator_result =
          case Creators.get_creator_by_username(username) do
            nil ->
              Creators.create_creator(%{tiktok_username: username})
              |> case do
                {:ok, creator} -> {:ok, creator, true}
                error -> error
              end

            existing ->
              {:ok, existing, false}
          end

        case creator_result do
          {:ok, creator, created?} ->
            video_attrs = %{
              creator_id: creator.id,
              tiktok_video_id: video_id,
              video_url: video_url,
              title: blank_to_nil(row["Video name"]),
              posted_at: parse_date(row["Video post date"]),
              gmv_cents: parse_money(row["GMV"]),
              items_sold: parse_int(row["Affiliate items sold "]),
              affiliate_orders: parse_int(row["Affiliate orders"]),
              impressions: parse_int(row["Shoppable video impressions"]),
              likes: parse_int(row["Shoppable video likes"]),
              comments: parse_int(row["Shoppable video comments"]),
              ctr: parse_percentage(row["Affiliate CTR"]),
              est_commission_cents: parse_money(row["Est. commission"])
            }

            case Creators.create_creator_video(brand_id, video_attrs) do
              {:ok, _video} ->
                {:ok, %{creator_created: if(created?, do: 1, else: 0)}}

              {:error, changeset} ->
                if has_unique_constraint_error?(changeset) do
                  {:ok, %{creator_created: 0}}
                else
                  {:error, changeset.errors}
                end
            end

          {:error, changeset} ->
            {:error, changeset.errors}
        end
      end
    end
  end

  @doc """
  Imports Refunnel performance metrics.

  Expected columns: username, profile, followers, emv, gmv, platform,
  last_post, total_posts, likes, comments, shares, engagement, impressions
  """
  def import_refunnel_data(file_path, brand_id) do
    {headers, rows} = parse_csv_with_headers(file_path)

    rows
    |> Stream.with_index(1)
    |> Enum.reduce(%{created: 0, updated: 0, snapshots: 0, errors: 0}, fn {row, index}, acc ->
      row = zip_headers(headers, row)

      case process_refunnel_row(row, brand_id) do
        {:ok, result} ->
          acc
          |> Map.update!(:created, &(&1 + (result[:created] || 0)))
          |> Map.update!(:updated, &(&1 + (result[:updated] || 0)))
          |> Map.update!(:snapshots, &(&1 + 1))

        {:error, _reason} ->
          if rem(index, 1000) == 0 do
            Logger.debug("Processed #{index} refunnel rows")
          end

          %{acc | errors: acc.errors + 1}
      end
    end)
    |> then(&{:ok, &1})
  end

  defp process_refunnel_row(row, brand_id) do
    username = row["username"]

    if blank?(username) do
      {:error, "Missing username"}
    else
      follower_count = parse_follower_count(row["followers"])
      gmv_cents = parse_money(row["gmv"])
      emv_cents = parse_money(row["emv"])

      creator_attrs = %{
        tiktok_username: username,
        tiktok_profile_url: blank_to_nil(row["profile"]),
        follower_count: follower_count,
        total_gmv_cents: gmv_cents,
        total_videos: parse_int(row["total_posts"])
      }

      # Upsert creator
      {action, creator} =
        case Creators.get_creator_by_username(username) do
          nil ->
            case Creators.create_creator(creator_attrs) do
              {:ok, c} -> {:created, c}
              {:error, cs} -> {:error, cs}
            end

          existing ->
            case Creators.update_creator(existing, creator_attrs) do
              {:ok, c} -> {:updated, c}
              {:error, cs} -> {:error, cs}
            end
        end

      case action do
        :error ->
          {:error, creator.errors}

        _ ->
          # Create performance snapshot
          snapshot_attrs = %{
            creator_id: creator.id,
            snapshot_date: Date.utc_today(),
            source: "refunnel",
            follower_count: follower_count,
            gmv_cents: gmv_cents,
            emv_cents: emv_cents,
            total_posts: parse_int(row["total_posts"]),
            total_likes: parse_int(row["likes"]),
            total_comments: parse_int(row["comments"]),
            total_shares: parse_int(row["shares"]),
            total_impressions: parse_int(row["impressions"]),
            engagement_count: parse_int(row["engagement"])
          }

          Creators.create_performance_snapshot(brand_id, snapshot_attrs)

          {:ok, %{action => 1}}
      end
    end
  end

  # Helper functions

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(str) when is_binary(str), do: String.trim(str) == ""
  defp blank?(_), do: false

  defp blank_to_nil(val) do
    if blank?(val), do: nil, else: String.trim(val)
  end

  defp phone_masked?(nil), do: true
  defp phone_masked?(""), do: true
  defp phone_masked?(phone), do: String.contains?(phone, "*")

  defp maybe_parse_address(attrs, nil), do: attrs
  defp maybe_parse_address(attrs, ""), do: attrs

  defp maybe_parse_address(attrs, address) do
    # Simple address parsing - try to extract city, state, zip
    # Format often: "123 Main St, City, ST 12345"
    parts = String.split(address, ",") |> Enum.map(&String.trim/1)

    case parts do
      [line1, city_state_zip] ->
        {city, state, zip} = parse_city_state_zip(city_state_zip)
        Map.merge(attrs, %{address_line_1: line1, city: city, state: state, zipcode: zip})

      [line1, line2, city_state_zip] ->
        {city, state, zip} = parse_city_state_zip(city_state_zip)

        Map.merge(attrs, %{
          address_line_1: line1,
          address_line_2: line2,
          city: city,
          state: state,
          zipcode: zip
        })

      [single] ->
        Map.put(attrs, :address_line_1, single)

      _ ->
        Map.put(attrs, :address_line_1, address)
    end
  end

  defp parse_city_state_zip(str) do
    # Try to match "City, ST 12345" or "City ST 12345"
    case Regex.run(~r/^(.+?),?\s+([A-Z]{2})\s+(\d{5}(?:-\d{4})?)$/, str) do
      [_, city, state, zip] -> {city, state, zip}
      nil -> {str, nil, nil}
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil
  defp parse_int("--"), do: nil

  defp parse_int(str) when is_binary(str) do
    str
    |> String.replace(~r/[^\d.-]/, "")
    |> case do
      "" -> nil
      cleaned -> String.to_integer(cleaned)
    end
  rescue
    _ -> nil
  end

  defp parse_int(val, default), do: parse_int(val) || default

  defp parse_money(nil), do: nil
  defp parse_money(""), do: nil
  defp parse_money("--"), do: nil

  defp parse_money(str) when is_binary(str) do
    str
    |> String.replace(~r/[$,]/, "")
    |> Float.parse()
    |> case do
      {amount, _} -> round(amount * 100)
      :error -> nil
    end
  rescue
    _ -> nil
  end

  defp parse_percentage(nil), do: nil
  defp parse_percentage(""), do: nil

  defp parse_percentage(str) when is_binary(str) do
    str
    |> String.replace("%", "")
    |> Float.parse()
    |> case do
      {pct, _} -> Decimal.from_float(pct / 100)
      :error -> nil
    end
  rescue
    _ -> nil
  end

  defp parse_follower_count(nil), do: nil
  defp parse_follower_count(""), do: nil

  defp parse_follower_count(str) when is_binary(str) do
    str = String.downcase(str)

    cond do
      String.contains?(str, "m") ->
        {num, _} = Float.parse(String.replace(str, "m", ""))
        round(num * 1_000_000)

      String.contains?(str, "k") ->
        {num, _} = Float.parse(String.replace(str, "k", ""))
        round(num * 1_000)

      true ->
        parse_int(str)
    end
  rescue
    _ -> nil
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(""), do: nil

  defp parse_datetime(str) when is_binary(str) do
    # Try parsing "11/26/2025 7:47:37 AM" format
    case Regex.run(~r/(\d{1,2})\/(\d{1,2})\/(\d{4})\s+(\d{1,2}):(\d{2}):(\d{2})\s*(AM|PM)?/i, str) do
      [_, month, day, year, hour, min, sec | maybe_ampm] ->
        hour = String.to_integer(hour)
        ampm = List.first(maybe_ampm)

        hour =
          cond do
            ampm && String.upcase(ampm) == "PM" && hour < 12 -> hour + 12
            ampm && String.upcase(ampm) == "AM" && hour == 12 -> 0
            true -> hour
          end

        {:ok, dt} =
          NaiveDateTime.new(
            String.to_integer(year),
            String.to_integer(month),
            String.to_integer(day),
            hour,
            String.to_integer(min),
            String.to_integer(sec)
          )

        DateTime.from_naive!(dt, "Etc/UTC")

      nil ->
        nil
    end
  rescue
    _ -> nil
  end

  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil

  defp parse_date(str) when is_binary(str) do
    # Try parsing "2025-08-07" format
    case Date.from_iso8601(str) do
      {:ok, date} ->
        {:ok, dt} = NaiveDateTime.new(date, ~T[00:00:00])
        DateTime.from_naive!(dt, "Etc/UTC")

      {:error, _} ->
        nil
    end
  rescue
    _ -> nil
  end

  defp extract_video_id(url) when is_binary(url) do
    case Regex.run(~r/\/video\/(\d+)/, url) do
      [_, id] -> id
      nil -> nil
    end
  end

  defp extract_video_id(_), do: nil

  defp map_order_status(nil), do: nil
  defp map_order_status(""), do: nil

  defp map_order_status(status) do
    status
    |> String.downcase()
    |> case do
      "delivered" -> "delivered"
      "shipped" -> "shipped"
      "to ship" -> "pending"
      "cancelled" -> "cancelled"
      "canceled" -> "cancelled"
      _ -> "pending"
    end
  end

  defp has_unique_constraint_error?(changeset) do
    Enum.any?(changeset.errors, fn
      {_field, {_msg, opts}} when is_list(opts) ->
        Keyword.get(opts, :constraint) == :unique

      _ ->
        false
    end)
  end

  # CSV Parsing Helpers

  @doc false
  defp parse_csv_with_headers(file_path, opts \\ []) do
    skip_rows = Keyword.get(opts, :skip_rows, 0)

    rows =
      file_path
      |> File.stream!()
      |> CreatorCSV.parse_stream(skip_headers: false)
      |> Enum.to_list()

    case rows do
      [headers | data_rows] ->
        # Clean headers - trim whitespace
        headers = Enum.map(headers, &String.trim/1)
        # Skip additional rows AFTER headers (e.g., description row)
        data_rows = Enum.drop(data_rows, skip_rows)
        {headers, data_rows}

      [] ->
        {[], []}
    end
  end

  @doc false
  defp zip_headers(headers, row) do
    headers
    |> Enum.zip(row)
    |> Map.new(fn {k, v} -> {k, v} end)
  end
end
