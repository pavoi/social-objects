defmodule Pavoi.Workers.BigQueryOrderSyncWorker do
  @moduledoc """
  Oban worker that syncs free sample orders from BigQuery TikTokShopOrders table
  to the Creator CRM.

  ## Sync Strategy

  Orders are matched to creators using a phone-first strategy:
  1. Match by normalized phone number (most reliable)
  2. Fall back to name matching (first + last name)
  3. Create new creator if no match found

  ## Data Flow

  BigQuery (TikTokShopOrders) -> Creator CRM (creators + creator_samples)

  - Free samples identified by `total_amount = 0`
  - Deduplication by `tiktok_order_id` to prevent duplicate samples
  - Creator contact info updated if missing
  """

  use Oban.Worker,
    queue: :bigquery,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing]]

  require Logger
  alias Pavoi.BigQuery
  alias Pavoi.Creators
  alias Pavoi.Repo
  alias Pavoi.Settings

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case resolve_brand_id(Map.get(args, "brand_id")) do
      {:ok, brand_id} ->
        Logger.info("Starting BigQuery TikTok orders sync...")

        Phoenix.PubSub.broadcast(
          Pavoi.PubSub,
          "bigquery:sync:#{brand_id}",
          {:bigquery_sync_started}
        )

        case sync_orders(brand_id) do
          {:ok, stats} ->
            Logger.info("""
            BigQuery orders sync completed successfully
               - Samples created: #{stats.samples_created}
               - Creators matched: #{stats.creators_matched}
               - Creators created: #{stats.creators_created}
               - Skipped (duplicate): #{stats.skipped}
               - Errors: #{stats.errors}
            """)

            Settings.update_bigquery_last_sync_at(brand_id)

            Phoenix.PubSub.broadcast(
              Pavoi.PubSub,
              "bigquery:sync:#{brand_id}",
              {:bigquery_sync_completed, stats}
            )

            :ok

          {:error, reason} ->
            Logger.error("BigQuery orders sync failed: #{inspect(reason)}")

            Phoenix.PubSub.broadcast(
              Pavoi.PubSub,
              "bigquery:sync:#{brand_id}",
              {:bigquery_sync_failed, reason}
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("[BigQuery] Failed to resolve brand_id: #{inspect(reason)}")
        {:discard, reason}
    end
  end

  defp sync_orders(brand_id) do
    with {:ok, bq_orders} <- fetch_free_sample_orders(brand_id) do
      Logger.info("Fetched #{length(bq_orders)} free sample orders from BigQuery")

      # Get existing order IDs for efficient filtering
      existing_order_ids = Creators.list_existing_order_ids(brand_id)
      Logger.info("Found #{MapSet.size(existing_order_ids)} existing orders in local DB")

      # Filter to only new orders
      new_orders =
        Enum.reject(bq_orders, fn order ->
          MapSet.member?(existing_order_ids, order["order_id"])
        end)

      Logger.info("Processing #{length(new_orders)} new orders")

      stats = process_orders(new_orders, brand_id)
      {:ok, Map.put(stats, :skipped, length(bq_orders) - length(new_orders))}
    end
  end

  defp fetch_free_sample_orders(brand_id) do
    # Join Orders with LineItems to get product details
    # Filter for free samples (total_amount = 0)
    # Exclude sku_type = 'NORMAL' which are gift-with-purchase promotions (free items bundled
    # with paid orders) - these are regular customers, not creators receiving samples
    # Include: UNKNOWN (creator samples), ZERO_LOTTERY (TikTok giveaway winners)
    # buyer_email is a TikTok forwarding address (e.g., xxx@scs.tiktokw.us) that forwards to the buyer
    dataset = Settings.get_bigquery_dataset(brand_id)

    if is_nil(dataset) or dataset == "" do
      {:error, :missing_bigquery_dataset}
    else
      sql = """
      SELECT
        CAST(o.order_id AS STRING) as order_id,
        o.recipient_name,
        o.recipient_phone_number as phone_number,
        o.buyer_email as email,
        o.recipient_full_address as full_address,
        o.recipient_address_line1 as address_line1,
        o.recipient_address_line2 as address_line2,
        o.recipient_address_line3 as city,
        o.recipient_address_line4 as state,
        o.recipient_postal_code as zipcode,
        o.recipient_region_code as country,
        o.created_at as create_time,
        li.product_name,
        li.sku_id,
        li.sku_name,
        li.quantity,
        li.order_status
      FROM `#{dataset}.TikTokShopOrders` o
      JOIN `#{dataset}.TikTokShopOrderLineItems` li
        ON CAST(o.order_id AS STRING) = li.order_id
      WHERE o.total_amount = 0
        AND li.sku_type != 'NORMAL'
      ORDER BY o.created_at DESC
      """

      BigQuery.query(sql, brand_id: brand_id)
    end
  end

  defp process_orders(orders, brand_id) do
    initial_stats = %{
      samples_created: 0,
      creators_matched: 0,
      creators_created: 0,
      errors: 0
    }

    total = length(orders)

    orders
    |> Enum.with_index(1)
    |> Enum.reduce(initial_stats, fn {order, index}, acc ->
      log_progress(index, total, acc)

      try do
        case process_single_order(order, brand_id) do
          {:ok, :created_creator} ->
            %{
              acc
              | samples_created: acc.samples_created + 1,
                creators_created: acc.creators_created + 1
            }

          {:ok, :matched_creator} ->
            %{
              acc
              | samples_created: acc.samples_created + 1,
                creators_matched: acc.creators_matched + 1
            }

          {:error, reason} ->
            if acc.errors < 5 do
              Logger.warning("Failed to process order #{order["order_id"]}: #{inspect(reason)}")
            end

            %{acc | errors: acc.errors + 1}
        end
      rescue
        e ->
          Logger.error("Exception processing order #{order["order_id"]}: #{Exception.message(e)}")
          %{acc | errors: acc.errors + 1}
      end
    end)
  end

  defp log_progress(index, total, stats) when rem(index, 100) == 0 do
    Logger.info(
      "Progress: #{index}/#{total} (#{stats.samples_created} samples, #{stats.creators_created} new creators, #{stats.errors} errors)"
    )
  end

  defp log_progress(_index, _total, _stats), do: :ok

  defp process_single_order(order, brand_id) do
    Repo.transaction(fn ->
      with {:ok, creator, status} <- find_or_create_creator(order),
           :ok <- ensure_brand_association(creator.id, brand_id),
           {:ok, _sample} <- create_sample(creator.id, brand_id, order) do
        status
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp find_or_create_creator(order) do
    normalized_phone = Creators.normalize_phone(order["phone_number"])
    {first_name, last_name} = Creators.parse_name(order["recipient_name"])
    usable_phone = get_usable_phone(normalized_phone)

    with nil <- find_creator_by_phone(usable_phone),
         nil <- find_creator_by_name(first_name, last_name) do
      create_new_creator(order, normalized_phone)
    else
      %{} = creator ->
        update_creator_from_order_data(creator, order)
        {:ok, creator, :matched_creator}
    end
  end

  defp get_usable_phone(nil), do: nil
  defp get_usable_phone(phone), do: if(String.contains?(phone, "*"), do: nil, else: phone)

  defp get_usable_email(nil), do: nil
  defp get_usable_email(""), do: nil
  defp get_usable_email(email), do: email

  defp find_creator_by_phone(nil), do: nil
  defp find_creator_by_phone(phone), do: Creators.get_creator_by_phone(phone)

  defp find_creator_by_name(first, last)
       when is_binary(first) and is_binary(last) and byte_size(first) > 1 and byte_size(last) > 1,
       do: Creators.get_creator_by_name(first, last)

  defp find_creator_by_name(_, _), do: nil

  # Comprehensive update of creator from order data - fills in missing OR masked fields
  # Masked data (containing *) is replaced with real data from BigQuery
  defp update_creator_from_order_data(creator, order) do
    {first_name, last_name} = Creators.parse_name(order["recipient_name"])
    normalized_phone = Creators.normalize_phone(order["phone_number"])
    phone_is_valid = normalized_phone && !String.contains?(normalized_phone, "*")
    {address_line1, city, state} = parse_address_fields(order)
    email = get_usable_email(order["email"])

    updates =
      build_field_updates(creator, [
        {:first_name, first_name},
        {:last_name, last_name},
        {:email, email},
        {:address_line_1, address_line1},
        {:address_line_2, order["address_line2"]},
        {:city, city},
        {:state, state},
        {:zipcode, order["zipcode"]},
        {:country, order["country"]}
      ])

    updates = maybe_add_phone_update(updates, creator, normalized_phone, phone_is_valid)

    if map_size(updates) > 0, do: Creators.update_creator(creator, updates), else: {:ok, creator}
  end

  defp build_field_updates(creator, field_pairs) do
    Enum.reduce(field_pairs, %{}, fn {field, value}, acc ->
      if needs_update?(Map.get(creator, field)) && value,
        do: Map.put(acc, field, value),
        else: acc
    end)
  end

  defp maybe_add_phone_update(updates, creator, phone, true = _valid) when not is_nil(phone) do
    if needs_update?(creator.phone),
      do: Map.merge(updates, %{phone: phone, phone_verified: true}),
      else: updates
  end

  defp maybe_add_phone_update(updates, _creator, _phone, _valid), do: updates

  # Check if a field needs to be updated (empty or contains masked data)
  defp needs_update?(nil), do: true
  defp needs_update?(""), do: true
  defp needs_update?(value) when is_binary(value), do: String.contains?(value, "*")
  defp needs_update?(_), do: false

  defp empty?(nil), do: true
  defp empty?(""), do: true
  defp empty?(_), do: false

  # Parse address fields - combine individual fields with parsed full_address
  # BigQuery full_address format: "Country, State, County, City, Street"
  # Example: "United States, California, Los Angeles, Santa Monica,1033 3rd St"
  defp parse_address_fields(order) do
    address_line1 = order["address_line1"]
    address_line2 = order["address_line2"]

    # Parse city and state from full_address since individual fields are usually empty
    {parsed_city, parsed_state} = parse_city_state_from_full_address(order["full_address"])

    # Use individual fields if available, otherwise fall back to parsed values
    city = if empty?(order["city"]), do: parsed_city, else: order["city"]
    state = if empty?(order["state"]), do: parsed_state, else: order["state"]

    # Build complete address_line1 from components if needed
    final_address =
      cond do
        !empty?(address_line1) && !empty?(address_line2) ->
          "#{address_line1}, #{address_line2}"

        !empty?(address_line1) ->
          address_line1

        true ->
          nil
      end

    {final_address, city, state}
  end

  # Parse city and state from TikTok's full_address format
  # Format: "Country, State, County, City, Street" or "Country, State, County, City,Street"
  defp parse_city_state_from_full_address(nil), do: {nil, nil}
  defp parse_city_state_from_full_address(""), do: {nil, nil}

  defp parse_city_state_from_full_address(full_address) do
    # Split by comma, handling the case where there's no space after comma
    parts =
      full_address
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case parts do
      # "United States, California, Los Angeles, Santa Monica, 1033 3rd St"
      [_country, state, _county, city | _street] ->
        {city, state}

      # Fallback for other formats
      [_country, state, city | _rest] ->
        {city, state}

      _ ->
        {nil, nil}
    end
  end

  defp create_new_creator(order, normalized_phone) do
    {first_name, last_name} = Creators.parse_name(order["recipient_name"])
    {address_line1, city, state} = parse_address_fields(order)

    # Only store phone if valid (not masked)
    phone_is_valid = normalized_phone && !String.contains?(normalized_phone, "*")

    # Email from BigQuery is a TikTok forwarding address (xxx@scs.tiktokw.us)
    # These are functional - emails sent to them forward to the buyer's real email
    email = get_usable_email(order["email"])

    attrs =
      %{
        first_name: first_name,
        last_name: last_name,
        phone: if(phone_is_valid, do: normalized_phone, else: nil),
        phone_verified: phone_is_valid,
        email: email,
        address_line_1: address_line1,
        address_line_2: order["address_line2"],
        city: city,
        state: state,
        zipcode: order["zipcode"],
        country: order["country"] || "US"
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Creators.create_creator(attrs) do
      {:ok, creator} -> {:ok, creator, :created_creator}
      {:error, changeset} -> {:error, {:create_creator_failed, changeset}}
    end
  end

  defp ensure_brand_association(creator_id, brand_id) do
    # on_conflict: :nothing returns {:ok, struct_or_nil}
    case Creators.add_creator_to_brand(creator_id, brand_id) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:brand_association_failed, reason}}
    end
  end

  defp create_sample(creator_id, brand_id, order) do
    # Parse timestamp
    ordered_at = parse_timestamp(order["create_time"])

    # Determine status from order_status field
    status = determine_sample_status(order["order_status"])

    # Parse quantity with fallback to 1
    quantity = parse_quantity(order["quantity"])

    attrs = %{
      creator_id: creator_id,
      brand_id: brand_id,
      tiktok_order_id: order["order_id"],
      tiktok_sku_id: order["sku_id"],
      product_name: order["product_name"] || order["sku_name"],
      variation: order["sku_name"],
      quantity: quantity,
      ordered_at: ordered_at,
      status: status
    }

    case Creators.create_creator_sample(attrs) do
      {:ok, sample} -> {:ok, sample}
      {:error, changeset} -> {:error, {:create_sample_failed, changeset}}
    end
  end

  defp parse_timestamp(nil), do: nil
  defp parse_timestamp(""), do: nil

  defp parse_timestamp(timestamp) when is_binary(timestamp) do
    # BigQuery DATETIME format: "2024-12-01T15:30:45" or "2024-12-01 15:30:45"
    # Try NaiveDateTime first (no timezone), then ISO8601 with timezone
    timestamp
    |> String.replace(" ", "T")
    |> parse_datetime_string()
  end

  defp parse_timestamp(_), do: nil

  defp parse_datetime_string(timestamp) do
    # Try parsing as NaiveDateTime first (BigQuery DATETIME has no timezone)
    case NaiveDateTime.from_iso8601(timestamp) do
      {:ok, naive} ->
        DateTime.from_naive!(naive, "Etc/UTC")

      {:error, _} ->
        # Try with timezone suffix
        case DateTime.from_iso8601(timestamp) do
          {:ok, datetime, _offset} -> datetime
          {:error, _} -> nil
        end
    end
  end

  defp parse_quantity(nil), do: 1
  defp parse_quantity(""), do: 1

  defp parse_quantity(quantity) when is_binary(quantity) do
    case Integer.parse(quantity) do
      {qty, _} when qty > 0 -> qty
      _ -> 1
    end
  end

  defp parse_quantity(quantity) when is_integer(quantity) and quantity > 0, do: quantity
  defp parse_quantity(_), do: 1

  defp determine_sample_status(order_status) do
    cond do
      order_status in ["DELIVERED", "delivered", "COMPLETED", "completed"] -> "delivered"
      order_status in ["SHIPPED", "shipped", "IN_TRANSIT", "in_transit"] -> "shipped"
      order_status in ["CANCELLED", "cancelled", "CANCELED", "canceled"] -> "cancelled"
      true -> "pending"
    end
  end

  defp normalize_brand_id(brand_id) when is_integer(brand_id), do: brand_id

  defp normalize_brand_id(brand_id) when is_binary(brand_id) do
    String.to_integer(brand_id)
  end

  defp resolve_brand_id(nil) do
    {:error, :brand_id_required}
  end

  defp resolve_brand_id(brand_id), do: {:ok, normalize_brand_id(brand_id)}

  @doc """
  Backfills contact info for creators who have BigQuery samples but missing or masked data.

  Call from IEx:
      Pavoi.Workers.BigQueryOrderSyncWorker.backfill_phones(brand_id)
  """
  def backfill_phones(brand_id) do
    import Ecto.Query

    Logger.info("Starting contact info backfill for creators with missing or masked data...")

    # Find creators with BigQuery samples that have:
    # - No phone, OR masked phone (contains *)
    # - No first_name, OR masked first_name (contains *)
    # This will catch creators that need any contact info updated
    creators_to_fix =
      Repo.all(
        from c in Pavoi.Creators.Creator,
          join: s in Pavoi.Creators.CreatorSample,
          on: s.creator_id == c.id,
          where:
            not is_nil(s.tiktok_order_id) and
              (is_nil(c.phone) or like(c.phone, "%*%") or
                 is_nil(c.first_name) or like(c.first_name, "%*%") or
                 like(c.address_line_1, "%*%")),
          group_by: [c.id],
          select: {c, fragment("array_agg(?)", s.tiktok_order_id)}
      )

    total = length(creators_to_fix)
    Logger.info("Found #{total} creators to backfill")

    # Batch order IDs for BigQuery lookup (max 1000 per query)
    all_order_ids =
      creators_to_fix
      |> Enum.flat_map(fn {_c, order_ids} -> order_ids end)
      |> Enum.uniq()

    Logger.info("Looking up #{length(all_order_ids)} unique orders in BigQuery...")

    # Fetch all orders from BigQuery in batches
    order_map = fetch_orders_in_batches(brand_id, all_order_ids)
    Logger.info("Retrieved #{map_size(order_map)} orders from BigQuery")

    # Update creators
    stats =
      creators_to_fix
      |> Enum.with_index(1)
      |> Enum.reduce(%{updated: 0, skipped: 0, errors: 0}, fn {{creator, order_ids}, idx}, acc ->
        if rem(idx, 100) == 0,
          do: Logger.info("Progress: #{idx}/#{total} (#{acc.updated} updated)")

        update_creator_from_orders(acc, creator, order_ids, order_map)
      end)

    Logger.info("""
    Phone backfill completed:
      - Updated: #{stats.updated}
      - Skipped (no order data): #{stats.skipped}
      - Errors: #{stats.errors}
    """)

    {:ok, stats}
  end

  @doc """
  Backfills email addresses for creators who have BigQuery samples but are missing email.

  Call from IEx:
      Pavoi.Workers.BigQueryOrderSyncWorker.backfill_emails(brand_id)
  """
  def backfill_emails(brand_id) do
    import Ecto.Query

    Logger.info("Starting email backfill for creators missing email...")

    # Find creators with BigQuery samples that have no email
    creators_to_fix =
      Repo.all(
        from c in Pavoi.Creators.Creator,
          join: s in Pavoi.Creators.CreatorSample,
          on: s.creator_id == c.id,
          where: not is_nil(s.tiktok_order_id) and (is_nil(c.email) or c.email == ""),
          group_by: [c.id],
          select: {c, fragment("array_agg(?)", s.tiktok_order_id)}
      )

    total = length(creators_to_fix)
    Logger.info("Found #{total} creators to backfill emails")

    # Batch order IDs for BigQuery lookup
    all_order_ids =
      creators_to_fix
      |> Enum.flat_map(fn {_c, order_ids} -> order_ids end)
      |> Enum.uniq()

    Logger.info("Looking up #{length(all_order_ids)} unique orders in BigQuery...")

    # Fetch all orders from BigQuery in batches
    order_map = fetch_orders_in_batches(brand_id, all_order_ids)
    Logger.info("Retrieved #{map_size(order_map)} orders from BigQuery")

    # Update creators with email only
    stats =
      creators_to_fix
      |> Enum.with_index(1)
      |> Enum.reduce(%{updated: 0, skipped: 0, errors: 0}, fn {{creator, order_ids}, idx}, acc ->
        if rem(idx, 100) == 0,
          do: Logger.info("Progress: #{idx}/#{total} (#{acc.updated} updated)")

        update_creator_email_from_orders(acc, creator, order_ids, order_map)
      end)

    Logger.info("""
    Email backfill completed:
      - Updated: #{stats.updated}
      - Skipped (no order data): #{stats.skipped}
      - Errors: #{stats.errors}
    """)

    {:ok, stats}
  end

  defp update_creator_email_from_orders(acc, creator, order_ids, order_map) do
    order = Enum.find_value(order_ids, fn oid -> Map.get(order_map, oid) end)
    do_update_creator_email(acc, creator, order)
  end

  defp do_update_creator_email(acc, _creator, nil), do: %{acc | skipped: acc.skipped + 1}

  defp do_update_creator_email(acc, creator, order) do
    case get_usable_email(order["email"]) do
      nil -> %{acc | skipped: acc.skipped + 1}
      email -> apply_email_update(acc, creator, email)
    end
  end

  defp apply_email_update(acc, creator, email) do
    case Creators.update_creator(creator, %{email: email}) do
      {:ok, _} -> %{acc | updated: acc.updated + 1}
      {:error, _} -> %{acc | errors: acc.errors + 1}
    end
  end

  defp update_creator_from_orders(acc, creator, order_ids, order_map) do
    # Get all orders for this creator and pick the best one (with unmasked phone if available)
    orders =
      order_ids
      |> Enum.map(&Map.get(order_map, &1))
      |> Enum.reject(&is_nil/1)

    order = pick_best_order(orders)
    do_update_creator(acc, creator, order)
  end

  # Pick the order with the best data - prefer orders with unmasked phone numbers
  defp pick_best_order([]), do: nil

  defp pick_best_order(orders) do
    Enum.max_by(orders, fn order ->
      phone = order["phone_number"]

      cond do
        # Best: has phone without asterisks
        phone && phone != "" && !String.contains?(phone, "*") -> 2
        # OK: has some phone data
        phone && phone != "" -> 1
        # Worst: no phone
        true -> 0
      end
    end)
  end

  defp do_update_creator(acc, _creator, nil), do: %{acc | skipped: acc.skipped + 1}

  defp do_update_creator(acc, creator, order) do
    case update_creator_from_order(creator, order) do
      {:ok, _} -> %{acc | updated: acc.updated + 1}
      {:error, _} -> %{acc | errors: acc.errors + 1}
    end
  end

  defp fetch_orders_in_batches(brand_id, order_ids) do
    order_ids
    |> Enum.chunk_every(500)
    |> Enum.reduce(%{}, fn batch, acc ->
      merge_batch_results(acc, fetch_orders_batch(brand_id, batch))
    end)
  end

  defp merge_batch_results(acc, {:ok, orders}) do
    Map.merge(acc, Map.new(orders, fn o -> {o["order_id"], o} end))
  end

  defp merge_batch_results(acc, {:error, reason}) do
    Logger.error("Failed to fetch batch: #{inspect(reason)}")
    acc
  end

  defp fetch_orders_batch(brand_id, order_ids) do
    ids_str = Enum.map_join(order_ids, ", ", &"\"#{&1}\"")

    dataset = Settings.get_bigquery_dataset(brand_id)

    if is_nil(dataset) or dataset == "" do
      {:error, :missing_bigquery_dataset}
    else
      sql = """
      SELECT
        CAST(order_id AS STRING) as order_id,
        recipient_name,
        recipient_phone_number as phone_number,
        buyer_email as email,
        recipient_full_address as full_address,
        recipient_address_line1 as address_line1,
        recipient_address_line2 as address_line2,
        recipient_address_line3 as city,
        recipient_address_line4 as state,
        recipient_postal_code as zipcode,
        recipient_region_code as country
      FROM `#{dataset}.TikTokShopOrders`
      WHERE CAST(order_id AS STRING) IN (#{ids_str})
      """

      BigQuery.query(sql, brand_id: brand_id)
    end
  end

  # Used by backfill - reuse the comprehensive update function
  defp update_creator_from_order(creator, order) do
    update_creator_from_order_data(creator, order)
  end
end
