# credo:disable-for-this-file Credo.Check.Refactor.Nesting
# credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
defmodule SocialObjects.Workers.CreatorImportWorker do
  @moduledoc """
  Oban worker that imports creator data from CSV files.

  Supports importing from multiple CSV sources:
  - Euka full contact/GMV data (email, phone, address, GMV, video/live counts)
  - Phone Numbers raw data (first/last name, phone)
  - Sample orders data (buyer info, products received)
  - Video performance data
  - Refunnel performance metrics

  ## Usage

  Queue an import job:

      %{source: "euka_full", file_path: "/path/to/file.csv", brand_id: 1}
      |> SocialObjects.Workers.CreatorImportWorker.new()
      |> Oban.insert()

  ## Import Sources

  - `"euka_full"` - Full Euka export with contact info, GMV, video/live counts, and products
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
  alias SocialObjects.Creators
  alias SocialObjects.Settings

  # Define CSV parser
  NimbleCSV.define(CreatorCSV, separator: ",", escape: "\"")

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source" => source, "file_path" => file_path} = args}) do
    brand_id = args["brand_id"]
    Logger.info("Starting creator import from #{source}: #{file_path}")

    # Broadcast start event
    _ = broadcast_import_event(source, brand_id, {:import_started, source})

    result =
      case source do
        "euka_full" -> import_euka_full_data(file_path, brand_id)
        "phone_numbers" -> import_phone_numbers(file_path)
        "samples" -> import_samples_data(file_path, brand_id)
        "videos" -> import_videos_data(file_path, brand_id)
        "refunnel" -> import_refunnel_data(file_path, brand_id)
        _ -> {:error, "Unknown source: #{source}"}
      end

    case result do
      {:ok, counts} ->
        Logger.info("✅ Import completed: #{inspect(counts)}")

        # Update timestamps based on source (euka_full handled in import function itself)
        _ =
          case source do
            "videos" -> Settings.update_videos_last_import_at(brand_id)
            _ -> nil
          end

        # Broadcast completion event
        _ = broadcast_import_event(source, brand_id, {:import_completed, source, counts})

        :ok

      {:error, reason} ->
        Logger.error("Import failed: #{inspect(reason)}")

        # Broadcast failure event
        _ = broadcast_import_event(source, brand_id, {:import_failed, source, reason})

        {:error, reason}
    end
  end

  # Broadcast to appropriate topics based on source
  # Dashboard expects atoms like :euka_import_started, :euka_import_completed, :euka_import_failed
  defp broadcast_import_event("euka_full", brand_id, {:import_started, _})
       when is_integer(brand_id) do
    event = {:euka_import_started, brand_id}
    _ = Phoenix.PubSub.broadcast(SocialObjects.PubSub, "euka:import:#{brand_id}", event)
    _ = Phoenix.PubSub.broadcast(SocialObjects.PubSub, "creators:import", event)
  end

  defp broadcast_import_event("euka_full", brand_id, {:import_completed, _, counts})
       when is_integer(brand_id) do
    event = {:euka_import_completed, brand_id, counts}
    _ = Phoenix.PubSub.broadcast(SocialObjects.PubSub, "euka:import:#{brand_id}", event)
    _ = Phoenix.PubSub.broadcast(SocialObjects.PubSub, "creators:import", event)
  end

  defp broadcast_import_event("euka_full", brand_id, {:import_failed, _, reason})
       when is_integer(brand_id) do
    event = {:euka_import_failed, brand_id, reason}
    _ = Phoenix.PubSub.broadcast(SocialObjects.PubSub, "euka:import:#{brand_id}", event)
    _ = Phoenix.PubSub.broadcast(SocialObjects.PubSub, "creators:import", event)
  end

  defp broadcast_import_event(_source, _brand_id, event) do
    _ = Phoenix.PubSub.broadcast(SocialObjects.PubSub, "creators:import", event)
  end

  @doc """
  Imports creator data from Euka full CSV export.

  Comprehensive import supporting:
  - Creator contact info (email, phone, address)
  - Brand-specific GMV seeding
  - Video/live counts
  - Product sample matching

  ## CSV Columns (flexible header detection):
  - handle: TikTok username (required)
  - email, phone, address: Contact info
  - PAVOI GMV ALL TIME / PAVOI ACTIVE GMV ALL TIME: GMV in dollars
  - PAVOI VIDEOS POSTED ALL TIME / PAVOI ACTIVE VIDEOS POSTED ALL TIME: Video count
  - PAVOI LIVES ALL TIME / PAVOI ACTIVE LIVES ALL TIME: Live count
  - products_sampled: Comma-separated product names

  ## Options
  - brand_id: Required - the brand to associate creators with
  """
  def import_euka_full_data(_file_path, nil),
    do: {:error, "brand_id is required for Euka full imports"}

  def import_euka_full_data(file_path, brand_id) do
    # Check for duplicate import
    case Creators.can_import_file?(brand_id, "euka", file_path) do
      {:error, :already_imported} ->
        {:error, "This file has already been imported"}

      {:ok, checksum} ->
        do_import_euka_full(file_path, brand_id, checksum)
    end
  end

  defp do_import_euka_full(file_path, brand_id, checksum) do
    # Create audit record - handle race condition where another import started
    case Creators.create_import_audit(%{
           brand_id: brand_id,
           source: "euka",
           file_path: file_path,
           file_checksum: checksum,
           status: "running",
           started_at: DateTime.utc_now()
         }) do
      {:ok, audit} ->
        do_import_euka_full_with_audit(file_path, brand_id, audit)

      {:error, changeset} ->
        # Check if it's a unique constraint error (race condition)
        if has_unique_constraint_error?(changeset) do
          {:error, "This file is already being imported or has been imported"}
        else
          {:error, "Failed to create import audit: #{inspect(changeset.errors)}"}
        end
    end
  end

  defp do_import_euka_full_with_audit(file_path, brand_id, audit) do
    # Load product name index for matching
    product_index = build_product_index(brand_id)

    # Stream process the file
    {stats, exception} =
      try do
        {stream_process_euka_file(file_path, brand_id, product_index, audit), nil}
      rescue
        e ->
          Logger.error("Euka import failed: #{inspect(e)}")

          stats = %{
            created: 0,
            updated: 0,
            samples: 0,
            errors: 1,
            error_details: [%{error: Exception.message(e)}]
          }

          {stats, e}
      end

    # Determine if this is a complete failure
    is_complete_failure =
      exception != nil or (stats.errors > 0 and stats.created + stats.updated == 0)

    status = if is_complete_failure, do: "failed", else: "completed"

    # Update audit record with final status
    {:ok, _} =
      Creators.update_import_audit(audit, %{
        status: status,
        finished_at: DateTime.utc_now(),
        rows_processed: stats.created + stats.updated + stats.errors,
        creators_created: stats.created,
        creators_updated: stats.updated,
        samples_created: stats.samples,
        error_count: stats.errors,
        errors_sample: %{errors: Enum.take(stats[:error_details] || [], 10)}
      })

    # Return error if complete failure, success otherwise
    if is_complete_failure do
      error_msg =
        if exception,
          do: Exception.message(exception),
          else: "Import failed with #{stats.errors} errors"

      {:error, error_msg}
    else
      # Update external import timestamp on success (works for both worker and direct calls)
      _ = Settings.update_external_import_last_at(brand_id)

      {:ok,
       %{
         created: stats.created,
         updated: stats.updated,
         samples: stats.samples,
         errors: stats.errors
       }}
    end
  end

  defp stream_process_euka_file(file_path, brand_id, product_index, audit) do
    # Parse headers using NimbleCSV (handles quoted columns with commas)
    headers =
      file_path
      |> File.stream!()
      |> CreatorCSV.parse_stream(skip_headers: false)
      |> Stream.take(1)
      |> Enum.to_list()
      |> List.first()
      |> Enum.map(&String.trim/1)

    # Build header mapping
    header_map = build_euka_header_map(headers)

    # Process rows with streaming (skip first row which is headers)
    file_path
    |> File.stream!()
    |> CreatorCSV.parse_stream(skip_headers: true)
    |> Stream.with_index(1)
    |> Enum.reduce(%{created: 0, updated: 0, samples: 0, errors: 0, error_details: []}, fn {row,
                                                                                            index},
                                                                                           acc ->
      row_data = zip_with_header_map(headers, row, header_map)

      case process_euka_full_row(row_data, brand_id, product_index) do
        {:ok, :created, sample_count} ->
          _ = maybe_broadcast_progress(index, audit.id)
          %{acc | created: acc.created + 1, samples: acc.samples + sample_count}

        {:ok, :updated, sample_count} ->
          _ = maybe_broadcast_progress(index, audit.id)
          %{acc | updated: acc.updated + 1, samples: acc.samples + sample_count}

        {:error, reason} ->
          if index <= 20 or rem(index, 1000) == 0 do
            Logger.warning("Euka row #{index} failed: #{inspect(reason)}")
          end

          new_errors =
            if length(acc.error_details) < 10 do
              [%{row: index, error: inspect(reason)} | acc.error_details]
            else
              acc.error_details
            end

          %{acc | errors: acc.errors + 1, error_details: new_errors}
      end
    end)
  end

  # Build header mapping for flexible column detection
  defp build_euka_header_map(headers) do
    headers
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {header, idx}, acc ->
      key = detect_euka_column(header)
      if key, do: Map.put(acc, key, idx), else: acc
    end)
  end

  # Detect column type from header name (case-insensitive, flexible matching)
  defp detect_euka_column(header) do
    header_lower = String.downcase(header)

    cond do
      header_lower == "handle" -> :handle
      header_lower == "email" -> :email
      header_lower == "phone" -> :phone
      header_lower == "address" -> :address
      String.contains?(header_lower, "gmv all time") -> :gmv
      String.contains?(header_lower, "videos posted all time") -> :video_count
      String.contains?(header_lower, "lives all time") -> :live_count
      header_lower == "products_sampled" -> :products_sampled
      true -> nil
    end
  end

  defp zip_with_header_map(headers, row, header_map) do
    # Create basic zip
    basic = Enum.zip(headers, row) |> Map.new()

    # Add mapped keys for easier access
    Enum.reduce(header_map, basic, fn {key, idx}, acc ->
      value = Enum.at(row, idx)
      Map.put(acc, key, value)
    end)
  end

  defp process_euka_full_row(row, brand_id, product_index) do
    username = row[:handle] || row["handle"]

    if blank?(username) do
      {:error, "Missing username"}
    else
      # Build creator attrs
      attrs = %{
        tiktok_username: String.downcase(String.trim(username)),
        email: row[:email] || row["email"],
        phone: row[:phone] || row["phone"]
      }

      # Parse address if present
      attrs = maybe_parse_address(attrs, row[:address] || row["address"])

      # Upsert creator with protection
      case Creators.upsert_creator_with_protection(attrs,
             update_enrichment: true,
             enrichment_source: "euka_import"
           ) do
        {:ok, creator, action} ->
          # Ensure creator is associated with brand
          _ = Creators.add_creator_to_brand(creator.id, brand_id)

          # Update brand_creator with GMV and counts
          _ = update_brand_creator_from_euka(brand_id, creator.id, row)

          # Process product samples
          sample_count = process_euka_products(creator.id, brand_id, row, product_index)

          {:ok, action, sample_count}

        {:error, changeset} ->
          {:error, changeset.errors}
      end
    end
  end

  defp update_brand_creator_from_euka(brand_id, creator_id, row) do
    # Parse GMV, video count, live count
    gmv_cents = parse_euka_gmv(row[:gmv] || row["gmv"])
    video_count = parse_int(row[:video_count] || row["video_count"])
    live_count = parse_int(row[:live_count] || row["live_count"])

    # Only update if we have data
    if gmv_cents || video_count || live_count do
      case Creators.get_brand_creator(brand_id, creator_id) do
        nil ->
          # Brand creator will be created by add_creator_to_brand
          nil

        bc ->
          updates = %{}

          # Seed GMV if provided and not already seeded
          # Note: cumulative_brand_gmv_cents has default: 0 in schema, so always an integer
          updates =
            if gmv_cents && gmv_cents > 0 && bc.cumulative_brand_gmv_cents == 0 do
              Map.merge(updates, %{
                cumulative_brand_gmv_cents: gmv_cents,
                gmv_seeded_externally: true,
                brand_gmv_tracking_started_at: Date.utc_today(),
                brand_gmv_last_synced_at: DateTime.utc_now()
              })
            else
              updates
            end

          # Update video/live counts
          updates =
            if video_count && video_count > 0 do
              Map.put(updates, :video_count, video_count)
            else
              updates
            end

          updates =
            if live_count && live_count > 0 do
              Map.put(updates, :live_count, live_count)
            else
              updates
            end

          if map_size(updates) > 0 do
            Creators.update_brand_creator(bc, updates)
          end
      end
    end
  end

  defp parse_euka_gmv(nil), do: nil
  defp parse_euka_gmv(""), do: nil

  defp parse_euka_gmv(str) when is_binary(str) do
    # Parse dollar amount to cents, e.g., "$1,234.56" -> 123456
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

  defp process_euka_products(creator_id, brand_id, row, product_index) do
    products_raw = row[:products_sampled] || row["products_sampled"]

    if blank?(products_raw) do
      0
    else
      # Parse products using resilient tokenizer
      products = parse_products_sampled(products_raw)

      # Match and create samples
      {matched, unmatched} =
        Enum.reduce(products, {[], []}, fn product_name, {matched_acc, unmatched_acc} ->
          case match_product(product_name, product_index) do
            {:ok, product_id} ->
              {[{product_name, product_id} | matched_acc], unmatched_acc}

            :no_match ->
              {matched_acc, [product_name | unmatched_acc]}
          end
        end)

      # Create sample records for matched products
      sample_count =
        Enum.reduce(matched, 0, fn {product_name, product_id}, count ->
          # Generate unique import key using creator_id (stable) instead of handle (mutable)
          import_key = generate_import_source_key(creator_id, product_name)

          sample_attrs = %{
            creator_id: creator_id,
            brand_id: brand_id,
            product_id: product_id,
            product_name: product_name,
            quantity: 1,
            import_source: "euka",
            import_source_key: import_key
          }

          case Creators.create_creator_sample(sample_attrs) do
            {:ok, _} -> count + 1
            # Likely duplicate
            {:error, _} -> count
          end
        end)

      # Store unmatched products in brand_creator for manual review
      _ =
        if length(unmatched) > 0 do
          case Creators.get_brand_creator(brand_id, creator_id) do
            nil ->
              nil

            bc ->
              # Parse existing unmatched products and dedupe with new ones
              existing_set =
                (bc.unmatched_products_raw || "")
                |> String.split("; ")
                |> Enum.map(&String.trim/1)
                |> Enum.reject(&(&1 == ""))
                |> MapSet.new()

              # Add new unmatched products, deduplicating
              combined_set =
                Enum.reduce(unmatched, existing_set, fn product, acc ->
                  MapSet.put(acc, String.trim(product))
                end)

              # Only update if there are new products
              if MapSet.size(combined_set) > MapSet.size(existing_set) do
                combined = combined_set |> MapSet.to_list() |> Enum.sort() |> Enum.join("; ")
                Creators.update_brand_creator(bc, %{unmatched_products_raw: combined})
              end
          end
        end

      sample_count
    end
  end

  # Parse products_sampled with resilient approach
  defp parse_products_sampled(raw_text) do
    raw_text
    # Split on ", PAVOI" preserving prefix
    |> String.split(~r/, (?=PAVOI)/i)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(fn s ->
      String.starts_with?(String.upcase(s), "PAVOI") and String.length(s) > 5
    end)
    |> Enum.uniq()
  end

  defp generate_import_source_key(creator_id, product_name) when is_integer(creator_id) do
    # Generate "{creator_id}:{md5_first_8_of_product_name}"
    # Uses creator_id (stable) instead of handle (mutable) for idempotency
    hash = :crypto.hash(:md5, product_name) |> Base.encode16(case: :lower) |> String.slice(0, 8)
    "#{creator_id}:#{hash}"
  end

  # Build product name index for matching
  defp build_product_index(brand_id) do
    alias SocialObjects.Catalog

    Catalog.list_products(brand_id)
    |> Enum.reduce(%{exact: %{}, prefix: %{}}, fn product, acc ->
      name = String.downcase(product.name || "")

      # Add exact match
      acc = put_in(acc, [:exact, name], product.id)

      # Add prefix match (first 100 chars)
      if String.length(name) > 0 do
        prefix = String.slice(name, 0, 100)
        put_in(acc, [:prefix, prefix], product.id)
      else
        acc
      end
    end)
  end

  defp match_product(product_name, product_index) do
    name_lower = String.downcase(String.trim(product_name))

    cond do
      # Exact match
      Map.has_key?(product_index.exact, name_lower) ->
        {:ok, product_index.exact[name_lower]}

      # Prefix match (handles truncation)
      Map.has_key?(product_index.prefix, String.slice(name_lower, 0, 100)) ->
        {:ok, product_index.prefix[String.slice(name_lower, 0, 100)]}

      # Fuzzy match with high threshold
      true ->
        case find_fuzzy_match(name_lower, product_index.exact) do
          {:ok, product_id} -> {:ok, product_id}
          :no_match -> :no_match
        end
    end
  end

  defp find_fuzzy_match(name, exact_index) do
    # Find best fuzzy match using Jaro-Winkler distance
    Enum.reduce(exact_index, {:no_match, 0.0}, fn {candidate, product_id}, {best, best_score} ->
      score = String.jaro_distance(name, candidate)

      if score >= 0.95 and score > best_score do
        {{:ok, product_id}, score}
      else
        {best, best_score}
      end
    end)
    |> elem(0)
  end

  defp maybe_broadcast_progress(index, audit_id) when rem(index, 500) == 0 do
    Phoenix.PubSub.broadcast(
      SocialObjects.PubSub,
      "euka:import:progress",
      {:import_progress, audit_id, index}
    )
  end

  defp maybe_broadcast_progress(_index, _audit_id), do: :ok

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
          _ = Creators.add_creator_to_brand(creator.id, brand_id)

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

          _ = Creators.create_performance_snapshot(brand_id, snapshot_attrs)

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
