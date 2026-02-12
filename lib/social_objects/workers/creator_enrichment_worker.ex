defmodule SocialObjects.Workers.CreatorEnrichmentWorker do
  @moduledoc """
  Oban worker that enriches creator profiles with data from TikTok Marketplace API.

  ## Enrichment Strategy

  1. Find creators with usernames but missing/stale metrics
  2. Search marketplace API by username to find exact match
  3. Update creator with metrics from API response
  4. Create performance snapshot for historical tracking

  ## Prioritization (Recently Sampled First)

  1. Creators with samples in last 30 days (highest priority)
  2. Creators with no performance data ever
  3. Creators with stale data (>7 days since last enrichment)

  ## Rate Limits

  - Marketplace Search API: reasonable limits
  - Process in batches to avoid overwhelming the API
  """

  use Oban.Worker,
    queue: :enrichment,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing]]

  require Logger
  import Ecto.Query

  alias SocialObjects.Creators
  alias SocialObjects.Creators.Creator
  alias SocialObjects.Repo
  alias SocialObjects.Settings
  alias SocialObjects.TiktokShop

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case resolve_brand_id(Map.get(args, "brand_id")) do
      {:ok, brand_id} ->
        # Check if we're still in cooldown from a recent rate limit
        case check_rate_limit_cooldown(brand_id) do
          {:cooldown, seconds_remaining} ->
            Logger.info(
              "[Enrichment] Still in cooldown (#{seconds_remaining}s remaining), skipping this run"
            )

            :ok

          :ok ->
            do_perform(brand_id, args)
        end

      {:error, reason} ->
        Logger.error("[Enrichment] Failed to resolve brand_id: #{inspect(reason)}")
        {:discard, reason}
    end
  end

  defp do_perform(brand_id, args) do
    Phoenix.PubSub.broadcast(
      SocialObjects.PubSub,
      "creator:enrichment:#{brand_id}",
      {:enrichment_started}
    )

    # Step 1: Sync sample orders to link creators to their tiktok_user_id
    # This runs first so newly-linked creators can be enriched in step 2
    # Default to 20 pages (~2000 orders) to avoid rate limits when combined with enrichment
    sample_sync_pages = Map.get(args, "sample_sync_pages", 20)

    case sync_sample_orders(brand_id, max_pages: sample_sync_pages) do
      {:ok, sample_stats} ->
        # Brief pause between sample sync and enrichment to avoid rate limits
        # Both use TikTok APIs that may share rate limit buckets
        Process.sleep(5_000)

        # Step 2: Enrich creators with marketplace data (followers, GMV, etc.)
        batch_size = Map.get(args, "batch_size", creator_batch_size())
        Logger.info("Starting creator enrichment (batch_size: #{batch_size})...")

        case enrich_creators(brand_id, batch_size) do
          {:ok, enrich_stats} ->
            Settings.update_enrichment_last_sync_at(brand_id)
            # Reset rate limit streak on successful completion
            Settings.reset_enrichment_rate_limit_streak(brand_id)

            Logger.info("""
            Creator enrichment completed
               Sample sync:
                 - Matched: #{sample_stats.matched}
                 - Created: #{sample_stats.created}
                 - Already linked: #{sample_stats.already_linked}
               Marketplace enrichment:
                 - Enriched: #{enrich_stats.enriched}
                 - Not found: #{enrich_stats.not_found}
                 - Errors: #{enrich_stats.errors}
                 - Skipped (no username): #{enrich_stats.skipped}
                 - Remaining to enrich: #{enrich_stats.remaining}
            """)

            combined_stats = Map.merge(sample_stats, enrich_stats)

            Phoenix.PubSub.broadcast(
              SocialObjects.PubSub,
              "creator:enrichment:#{brand_id}",
              {:enrichment_completed, combined_stats}
            )

            :ok

          {:error, reason} ->
            handle_enrichment_error(brand_id, reason)
        end

      {:error, reason} ->
        handle_enrichment_error(brand_id, reason)
    end
  end

  @doc """
  Manually trigger enrichment for a specific creator by username.
  Returns {:ok, creator} or {:error, reason}.
  """
  def enrich_single(brand_id, creator) when is_struct(creator, Creator) do
    if creator.tiktok_username && creator.tiktok_username != "" do
      enrich_creator(brand_id, creator)
    else
      {:error, :no_username}
    end
  end

  defp handle_enrichment_error(brand_id, reason) do
    if rate_limited_reason?(reason) do
      # Record the rate limit and get exponential backoff duration
      streak = Settings.record_enrichment_rate_limit(brand_id)
      backoff_seconds = calculate_backoff(streak)

      Logger.warning(
        "Creator enrichment rate limited (streak: #{streak}). Backing off for #{div(backoff_seconds, 60)} minutes."
      )

      Phoenix.PubSub.broadcast(
        SocialObjects.PubSub,
        "creator:enrichment:#{brand_id}",
        {:enrichment_failed, :rate_limited}
      )

      {:snooze, backoff_seconds}
    else
      Logger.error("Creator enrichment failed: #{inspect(reason)}")

      Phoenix.PubSub.broadcast(
        SocialObjects.PubSub,
        "creator:enrichment:#{brand_id}",
        {:enrichment_failed, reason}
      )

      {:error, reason}
    end
  end

  defp calculate_backoff(streak) do
    # Exponential backoff: 15min, 30min, 60min, 120min (max)
    # Formula: initial * 2^(streak-1), capped at max
    base = rate_limit_initial_backoff_seconds()
    multiplier = :math.pow(2, min(streak - 1, 3)) |> round()
    min(base * multiplier, rate_limit_max_backoff_seconds())
  end

  defp check_rate_limit_cooldown(brand_id) do
    case Settings.get_enrichment_last_rate_limited_at(brand_id) do
      nil ->
        :ok

      last_rate_limited_at ->
        now = DateTime.utc_now()
        seconds_since = DateTime.diff(now, last_rate_limited_at, :second)

        cooldown_seconds = rate_limit_cooldown_seconds()

        if seconds_since < cooldown_seconds do
          {:cooldown, cooldown_seconds - seconds_since}
        else
          :ok
        end
    end
  end

  # =============================================================================
  # Sample Order Sync - Link creators to their TikTok user_id via sample orders
  # =============================================================================

  @doc """
  Syncs sample orders from TikTok API to identify and link creators.

  For sample orders (is_sample_order=true), the `user_id` field contains the
  creator's TikTok user ID (not a customer). This function:

  1. Fetches all orders from TikTok Orders API
  2. Filters for `is_sample_order == true`
  3. Matches to existing creators by phone/name
  4. Sets `tiktok_user_id` on matched creators
  5. Creates new creators for unmatched samples

  Call manually:
      SocialObjects.Workers.CreatorEnrichmentWorker.sync_sample_orders(brand_id)
  """
  def sync_sample_orders(brand_id, opts \\ []) do
    max_pages = Keyword.get(opts, :max_pages, 100)
    Logger.info("[SampleSync] Starting sample orders sync (max_pages: #{max_pages})...")

    # Initialize context for sample creation
    context = %{
      brand_id: brand_id,
      existing_order_ids: Creators.list_existing_order_ids(brand_id)
    }

    Logger.info(
      "[SampleSync] Found #{MapSet.size(context.existing_order_ids)} existing sample orders"
    )

    initial_stats = %{
      matched: 0,
      created: 0,
      already_linked: 0,
      skipped: 0,
      errors: 0,
      pages: 0,
      samples_created: 0,
      samples_skipped: 0
    }

    case sync_sample_orders_page(nil, initial_stats, context, max_pages) do
      {:ok, stats} ->
        Logger.info("""
        [SampleSync] Completed
           - Matched existing creators: #{stats.matched}
           - Created new creators: #{stats.created}
           - Already linked: #{stats.already_linked}
           - Skipped (no match data): #{stats.skipped}
           - Samples created: #{stats.samples_created}
           - Samples skipped (duplicate): #{stats.samples_skipped}
           - Errors: #{stats.errors}
           - Pages processed: #{stats.pages}
        """)

        {:ok, stats}

      {:error, reason} ->
        if rate_limited_reason?(reason) do
          Logger.warning("[SampleSync] Rate limited by TikTok API, backing off")
        else
          Logger.error("[SampleSync] Failed: #{inspect(reason)}")
        end

        {:error, reason}
    end
  end

  defp sync_sample_orders_page(_page_token, stats, _context, max_pages)
       when stats.pages >= max_pages do
    Logger.info("[SampleSync] Reached max pages limit (#{max_pages})")
    {:ok, stats}
  end

  defp sync_sample_orders_page(page_token, stats, context, max_pages) do
    params = build_page_params(page_token)
    brand_id = context.brand_id

    case TiktokShop.make_api_request(brand_id, :post, "/order/202309/orders/search", params, %{}) do
      {:ok, %{"data" => data}} ->
        Process.sleep(api_delay_ms())
        handle_orders_response(data, stats, context, max_pages)

      {:error, reason} ->
        if rate_limited_reason?(reason) do
          Logger.warning("[SampleSync] Rate limited by TikTok API, stopping early")
          {:error, reason}
        else
          Logger.error("[SampleSync] API error: #{inspect(reason)}")
          {:ok, stats}
        end
    end
  end

  defp build_page_params(nil), do: %{page_size: 100}
  defp build_page_params(token), do: %{page_size: 100, page_token: token}

  defp handle_orders_response(data, stats, context, max_pages) do
    orders = Map.get(data, "orders", [])
    sample_orders = Enum.filter(orders, fn o -> o["is_sample_order"] == true end)

    new_stats = process_sample_orders(sample_orders, stats, context)
    new_stats = %{new_stats | pages: new_stats.pages + 1}

    maybe_continue_pagination(data["next_page_token"], new_stats, context, max_pages)
  end

  defp maybe_continue_pagination(token, stats, context, max_pages)
       when is_binary(token) and token != "" and stats.pages < max_pages do
    sync_sample_orders_page(token, stats, context, max_pages)
  end

  defp maybe_continue_pagination(_token, stats, _context, _max_pages), do: {:ok, stats}

  defp process_sample_orders(orders, stats, context) do
    Enum.reduce(orders, stats, fn order, acc ->
      process_single_sample_order(order, acc, context)
    end)
  end

  defp process_single_sample_order(order, acc, context) do
    user_id = order["user_id"]
    order_id = order["id"]
    recipient = order["recipient_address"] || %{}

    # Extract contact info (may be masked or unmasked)
    phone = extract_phone(recipient["phone_number"])
    name = recipient["name"] || ""
    {first_name, last_name} = Creators.parse_name(name)

    if is_nil(user_id) or user_id == "" do
      %{acc | skipped: acc.skipped + 1}
    else
      # First, find or create the creator
      {creator, acc} =
        case find_creator_for_sample(phone, first_name, last_name) do
          {:found, creator} ->
            {creator, link_creator_to_user_id(creator, user_id, recipient, acc)}

          :not_found ->
            create_creator_from_sample_with_return(user_id, recipient, acc)
        end

      # Then, create sample records for each line item (if we have a creator)
      if creator do
        create_samples_for_order(order, order_id, creator.id, acc, context)
      else
        acc
      end
    end
  rescue
    e ->
      Logger.error("[SampleSync] Error processing order: #{Exception.message(e)}")
      %{acc | errors: acc.errors + 1}
  end

  defp find_creator_for_sample(phone, first_name, last_name) do
    # Try exact phone match first (for unmasked phones)
    creator =
      if phone && !phone_is_masked?(phone) do
        Creators.get_creator_by_phone(phone)
      else
        nil
      end

    # Try partial phone match (for masked phones like "(+1)808*****50")
    creator =
      creator || try_partial_phone_match(phone)

    # Fall back to name match
    creator =
      creator ||
        if first_name && String.length(first_name) > 1 && !String.contains?(first_name, "*") do
          Creators.get_creator_by_name(first_name, last_name)
        else
          nil
        end

    if creator, do: {:found, creator}, else: :not_found
  end

  defp try_partial_phone_match(nil), do: nil
  defp try_partial_phone_match(""), do: nil

  defp try_partial_phone_match(phone) do
    # Extract area code and last digits from masked phone like "(+1)808*****50"
    case Regex.run(~r/\+1\)?(\d{3})\*+(\d+)$/, phone) do
      [_, area_code, last_digits] when byte_size(last_digits) >= 2 ->
        pattern = "%#{area_code}%#{last_digits}"

        # Find creators matching the pattern - prefer exact matches
        matches =
          from(c in Creator,
            where: like(c.phone, ^pattern),
            limit: 5
          )
          |> Repo.all()

        # Return first match if only one, nil if ambiguous
        case matches do
          [single] -> single
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp link_creator_to_user_id(creator, user_id, recipient, acc) do
    if creator.tiktok_user_id do
      # Already has a user_id - check if it matches
      if creator.tiktok_user_id == user_id do
        %{acc | already_linked: acc.already_linked + 1}
      else
        # Different user_id - log warning but don't overwrite
        Logger.warning(
          "[SampleSync] Creator #{creator.id} has different tiktok_user_id: #{creator.tiktok_user_id} vs #{user_id}"
        )

        %{acc | already_linked: acc.already_linked + 1}
      end
    else
      # Set the user_id and update any missing contact info
      attrs = build_update_attrs(creator, user_id, recipient)

      case Creators.update_creator(creator, attrs) do
        {:ok, _updated} ->
          Logger.debug(
            "[SampleSync] Linked creator #{creator.id} (#{creator.first_name} #{creator.last_name}) to user_id #{user_id}"
          )

          %{acc | matched: acc.matched + 1}

        {:error, changeset} ->
          Logger.warning(
            "[SampleSync] Failed to update creator #{creator.id}: #{inspect(changeset.errors)}"
          )

          %{acc | errors: acc.errors + 1}
      end
    end
  end

  defp build_update_attrs(creator, user_id, recipient) do
    phone = extract_phone(recipient["phone_number"])
    name = recipient["name"] || ""
    {first_name, last_name} = Creators.parse_name(name)
    protected = creator.manually_edited_fields || []

    %{tiktok_user_id: user_id}
    |> maybe_add_phone(creator, phone, protected)
    |> maybe_add_name(creator, first_name, last_name, protected)
    |> maybe_add_address(creator, recipient, protected)
  end

  defp maybe_add_phone(attrs, creator, phone, protected) do
    if is_nil(creator.phone) && phone && !phone_is_masked?(phone) &&
         !field_protected?(:phone, protected) do
      Map.merge(attrs, %{phone: phone, phone_verified: true})
    else
      attrs
    end
  end

  defp maybe_add_name(attrs, creator, first_name, last_name, protected) do
    attrs
    |> maybe_put_if_missing(creator, :first_name, first_name, protected)
    |> maybe_put_if_missing(creator, :last_name, last_name, protected)
  end

  defp maybe_put_if_missing(attrs, creator, field, value, protected) do
    current = Map.get(creator, field)

    if is_nil(current) && value && !String.contains?(value, "*") &&
         !field_protected?(field, protected) do
      Map.put(attrs, field, value)
    else
      attrs
    end
  end

  defp maybe_add_address(attrs, creator, recipient, protected) do
    district_info = recipient["district_info"] || []

    # Extract location from district_info
    city = find_district_value(district_info, "City")
    state = find_district_value(district_info, "State")
    country = find_district_value(district_info, "Country")

    # Get street address and postal code directly from recipient
    address_line1 = recipient["address_line1"]
    postal_code = recipient["postal_code"]

    attrs =
      if should_update_field?(creator.address_line_1, address_line1, :address_line_1, protected) do
        Map.put(attrs, :address_line_1, address_line1)
      else
        attrs
      end

    attrs =
      if should_update_field?(creator.zipcode, postal_code, :zipcode, protected) do
        Map.put(attrs, :zipcode, postal_code)
      else
        attrs
      end

    attrs =
      if should_update_field?(creator.city, city, :city, protected) do
        Map.put(attrs, :city, city)
      else
        attrs
      end

    attrs =
      if should_update_field?(creator.state, state, :state, protected) do
        Map.put(attrs, :state, state)
      else
        attrs
      end

    attrs =
      if is_nil(creator.country) && country && !field_protected?(:country, protected) do
        Map.put(attrs, :country, country)
      else
        attrs
      end

    attrs
  end

  # Update field if: current is nil/empty OR current is masked, AND new value is unmasked, AND field not protected
  defp should_update_field?(current, new, field, protected) do
    has_new = new && new != "" && !String.contains?(new, "*")
    needs_update = is_nil(current) || current == "" || String.contains?(current || "", "*")
    not_protected = !field_protected?(field, protected)
    has_new && needs_update && not_protected
  end

  # Check if a field is in the manually_edited_fields list
  defp field_protected?(field, protected) when is_atom(field) do
    Atom.to_string(field) in protected
  end

  defp find_district_value(district_info, level_name) do
    case Enum.find(district_info, fn d -> d["address_level_name"] == level_name end) do
      %{"address_name" => name} -> name
      _ -> nil
    end
  end

  # Returns {creator, acc} for use when we need the creator for sample creation
  defp create_creator_from_sample_with_return(user_id, recipient, acc) do
    case Creators.get_creator_by_tiktok_user_id(user_id) do
      %Creator{} = existing ->
        Logger.debug("[SampleSync] Found existing creator #{existing.id} with user_id #{user_id}")
        {existing, %{acc | already_linked: acc.already_linked + 1}}

      nil ->
        do_create_creator_from_sample(user_id, recipient, acc)
    end
  end

  defp do_create_creator_from_sample(user_id, recipient, acc) do
    phone = extract_phone(recipient["phone_number"])
    name = recipient["name"] || ""
    {first_name, last_name} = Creators.parse_name(name)
    district_info = recipient["district_info"] || []

    attrs =
      %{
        tiktok_user_id: user_id,
        country: find_district_value(district_info, "Country") || "US"
      }
      |> maybe_put(:phone, phone, &(!phone_is_masked?(&1)))
      |> maybe_put(:phone_verified, true, fn _ -> !phone_is_masked?(phone) end)
      |> maybe_put(:first_name, first_name, &(!String.contains?(&1, "*")))
      |> maybe_put(:last_name, last_name, &(!String.contains?(&1 || "", "*")))
      |> maybe_put(:address_line_1, recipient["address_line1"], &(!String.contains?(&1, "*")))
      |> maybe_put(:zipcode, recipient["postal_code"], &(!String.contains?(&1, "*")))
      |> maybe_put(
        :city,
        find_district_value(district_info, "City"),
        &(!String.contains?(&1, "*"))
      )
      |> maybe_put(
        :state,
        find_district_value(district_info, "State"),
        &(!String.contains?(&1, "*"))
      )

    case Creators.create_creator(attrs) do
      {:ok, creator} ->
        Logger.debug("[SampleSync] Created new creator #{creator.id} with user_id #{user_id}")
        {creator, %{acc | created: acc.created + 1}}

      {:error, changeset} ->
        Logger.warning("[SampleSync] Failed to create creator: #{inspect(changeset.errors)}")
        {nil, %{acc | errors: acc.errors + 1}}
    end
  end

  # Creates CreatorSample records for each line item in an order
  defp create_samples_for_order(order, order_id, creator_id, acc, context) do
    %{brand_id: brand_id, existing_order_ids: existing_order_ids} = context

    # Skip if we've already processed this order
    if MapSet.member?(existing_order_ids, order_id) do
      %{acc | samples_skipped: acc.samples_skipped + 1}
    else
      Creators.add_creator_to_brand(creator_id, brand_id)

      line_items = order["line_items"] || []
      ordered_at = parse_order_timestamp(order["create_time"])
      status = determine_sample_status(order["status"])

      Enum.reduce(line_items, acc, fn item, item_acc ->
        create_sample_from_line_item(
          item,
          order_id,
          creator_id,
          brand_id,
          ordered_at,
          status,
          item_acc
        )
      end)
    end
  end

  defp create_sample_from_line_item(item, order_id, creator_id, brand_id, ordered_at, status, acc) do
    attrs = %{
      creator_id: creator_id,
      brand_id: brand_id,
      tiktok_order_id: order_id,
      tiktok_sku_id: item["sku_id"],
      product_name: item["product_name"],
      variation: item["sku_name"],
      quantity: 1,
      ordered_at: ordered_at,
      status: status
    }

    case Creators.create_creator_sample(attrs) do
      {:ok, _sample} ->
        %{acc | samples_created: acc.samples_created + 1}

      {:error, %Ecto.Changeset{errors: errors}} ->
        # Check if it's a duplicate constraint error (already exists)
        if Keyword.has_key?(errors, :tiktok_order_id) do
          %{acc | samples_skipped: acc.samples_skipped + 1}
        else
          Logger.warning(
            "[SampleSync] Failed to create sample for order #{order_id}: #{inspect(errors)}"
          )

          acc
        end
    end
  end

  defp parse_order_timestamp(nil), do: nil
  defp parse_order_timestamp(unix) when is_integer(unix), do: DateTime.from_unix!(unix)
  defp parse_order_timestamp(_), do: nil

  defp determine_sample_status(order_status) do
    case order_status do
      "DELIVERED" -> "delivered"
      "COMPLETED" -> "delivered"
      "IN_TRANSIT" -> "shipped"
      "AWAITING_SHIPMENT" -> "pending"
      "AWAITING_COLLECTION" -> "shipped"
      "CANCELLED" -> "cancelled"
      _ -> "pending"
    end
  end

  defp maybe_put(map, _key, nil, _validator), do: map
  defp maybe_put(map, _key, "", _validator), do: map

  defp maybe_put(map, key, value, validator) do
    if validator.(value) do
      Map.put(map, key, value)
    else
      map
    end
  end

  defp extract_phone(nil), do: nil
  defp extract_phone(""), do: nil

  defp extract_phone(phone) do
    # Normalize phone format: "(+1)8085551234" -> "+18085551234"
    phone
    |> String.replace(~r/[()]/, "")
    |> Creators.normalize_phone()
  end

  defp phone_is_masked?(nil), do: true
  defp phone_is_masked?(""), do: true
  defp phone_is_masked?(phone), do: String.contains?(phone, "*")

  defp enrich_creators(brand_id, batch_size) do
    # Get total count of creators needing enrichment for progress tracking
    total_needing_enrichment = count_creators_needing_enrichment(brand_id)
    creators = get_creators_to_enrich(brand_id, batch_size)

    Logger.info(
      "Found #{length(creators)} creators to enrich this batch (#{total_needing_enrichment} total remaining)"
    )

    initial_stats = %{enriched: 0, not_found: 0, errors: 0, skipped: 0, remaining: 0}

    initial_state = %{
      stats: initial_stats,
      rate_limit_streak: 0,
      last_rate_limit_reason: nil,
      halted_reason: nil
    }

    final_state =
      Enum.reduce_while(creators, initial_state, fn creator, state ->
        process_creator(brand_id, creator, state)
      end)

    # Calculate remaining after this batch
    remaining = max(0, total_needing_enrichment - final_state.stats.enriched)
    final_stats = Map.put(final_state.stats, :remaining, remaining)

    case final_state.halted_reason do
      :rate_limited ->
        Logger.warning("""
        Marketplace API rate limited #{rate_limit_max_consecutive()} times in a row; stopping enrichment early.
        Last error: #{inspect(final_state.last_rate_limit_reason)}
        """)

        {:error, final_state.last_rate_limit_reason || :rate_limited}

      nil ->
        {:ok, final_stats}
    end
  end

  defp count_creators_needing_enrichment(brand_id) do
    seven_days_ago = DateTime.add(DateTime.utc_now(), -7, :day)

    query =
      from(c in Creator,
        join: bc in SocialObjects.Creators.BrandCreator,
        on: bc.creator_id == c.id,
        where: not is_nil(c.tiktok_username) and c.tiktok_username != "",
        where: bc.brand_id == ^brand_id,
        where: is_nil(c.last_enriched_at) or c.last_enriched_at < ^seven_days_ago,
        select: count(c.id)
      )

    Repo.one(query) || 0
  end

  defp process_creator(_brand_id, %Creator{tiktok_username: nil}, state) do
    skip_creator(state)
  end

  defp process_creator(_brand_id, %Creator{tiktok_username: ""}, state) do
    skip_creator(state)
  end

  defp process_creator(brand_id, creator, state) do
    stats = state.stats

    if stats.enriched > 0, do: Process.sleep(api_delay_ms())

    result = enrich_creator(brand_id, creator)
    new_stats = update_stats(result, stats)
    process_creator_result(result, new_stats, state)
  end

  defp skip_creator(state) do
    stats = state.stats
    new_stats = %{stats | skipped: stats.skipped + 1}
    new_state = %{state | stats: new_stats}
    {:cont, reset_rate_limit_state(new_state)}
  end

  defp process_creator_result({:error, reason}, new_stats, state) do
    if rate_limited_reason?(reason) do
      handle_rate_limit(new_stats, reason, state)
    else
      {:cont, reset_rate_limit_state(%{state | stats: new_stats})}
    end
  end

  defp process_creator_result(_result, new_stats, state) do
    {:cont, reset_rate_limit_state(%{state | stats: new_stats})}
  end

  defp handle_rate_limit(new_stats, reason, state) do
    new_streak = state.rate_limit_streak + 1

    new_state = %{
      state
      | stats: new_stats,
        rate_limit_streak: new_streak,
        last_rate_limit_reason: reason
    }

    if new_streak >= rate_limit_max_consecutive() do
      {:halt, %{new_state | halted_reason: :rate_limited}}
    else
      {:cont, new_state}
    end
  end

  defp reset_rate_limit_state(state) do
    %{state | rate_limit_streak: 0, last_rate_limit_reason: nil}
  end

  defp update_stats({:ok, _}, acc), do: %{acc | enriched: acc.enriched + 1}
  defp update_stats({:error, :not_found}, acc), do: %{acc | not_found: acc.not_found + 1}
  defp update_stats({:error, _}, acc), do: %{acc | errors: acc.errors + 1}

  defp rate_limited_reason?(:rate_limited), do: true
  defp rate_limited_reason?({:rate_limited, _}), do: true

  defp rate_limited_reason?(reason) when is_binary(reason) do
    String.contains?(reason, "HTTP 429")
  end

  defp rate_limited_reason?(_reason), do: false

  defp creator_batch_size do
    enrichment_config()
    |> Keyword.get(:batch_size, 75)
  end

  defp api_delay_ms do
    enrichment_config()
    |> Keyword.get(:api_delay_ms, 300)
  end

  defp rate_limit_max_consecutive do
    enrichment_config()
    |> Keyword.get(:rate_limit_max_consecutive, 3)
  end

  defp rate_limit_initial_backoff_seconds do
    enrichment_config()
    |> Keyword.get(:rate_limit_initial_backoff_seconds, 15 * 60)
  end

  defp rate_limit_max_backoff_seconds do
    enrichment_config()
    |> Keyword.get(:rate_limit_max_backoff_seconds, 2 * 60 * 60)
  end

  defp rate_limit_cooldown_seconds do
    enrichment_config()
    |> Keyword.get(:rate_limit_cooldown_seconds, 10 * 60)
  end

  defp enrichment_config do
    Application.get_env(:social_objects, :worker_tuning, [])
    |> Keyword.get(:creator_enrichment, [])
  end

  defp normalize_brand_id(brand_id) when is_integer(brand_id), do: brand_id

  defp normalize_brand_id(brand_id) when is_binary(brand_id) do
    String.to_integer(brand_id)
  end

  defp resolve_brand_id(nil) do
    {:error, :brand_id_required}
  end

  defp resolve_brand_id(brand_id), do: {:ok, normalize_brand_id(brand_id)}

  defp get_creators_to_enrich(brand_id, limit) do
    # Prioritize:
    # 1. Creators with recent samples (last 30 days)
    # 2. Creators with no enrichment data
    # 3. Creators with stale data (>7 days)

    thirty_days_ago = DateTime.add(DateTime.utc_now(), -30, :day)
    seven_days_ago = DateTime.add(DateTime.utc_now(), -7, :day)

    # Query creators who need enrichment, prioritized by sample recency
    query =
      from(c in Creator,
        join: bc in SocialObjects.Creators.BrandCreator,
        on: bc.creator_id == c.id,
        left_join: s in assoc(c, :creator_samples),
        on: s.brand_id == ^brand_id,
        where: bc.brand_id == ^brand_id,
        where: not is_nil(c.tiktok_username) and c.tiktok_username != "",
        where:
          is_nil(c.last_enriched_at) or
            c.last_enriched_at < ^seven_days_ago,
        group_by: c.id,
        order_by: [
          # Prioritize creators with recent samples
          desc: fragment("MAX(?) > ?", s.ordered_at, ^thirty_days_ago),
          # Then by whether they've never been enriched
          asc: c.last_enriched_at,
          # Then by total GMV (enrich higher-value creators first)
          desc: c.total_gmv_cents
        ],
        limit: ^limit,
        select: c
      )

    Repo.all(query)
  end

  defp enrich_creator(brand_id, creator) do
    # Prefer user_id-based enrichment (more reliable, handles username changes)
    # Fall back to username search if no user_id available
    if creator.tiktok_user_id && creator.tiktok_user_id != "" do
      enrich_creator_by_user_id(brand_id, creator)
    else
      enrich_creator_by_username(brand_id, creator)
    end
  end

  # Enrich using stable user_id - can detect handle changes
  defp enrich_creator_by_user_id(brand_id, creator) do
    case TiktokShop.get_marketplace_creator(brand_id, creator.tiktok_user_id) do
      {:ok, marketplace_data} ->
        # Check if handle changed
        current_username = marketplace_data["username"]
        handle_change = detect_handle_change(creator, current_username)
        update_creator_from_marketplace(brand_id, creator, marketplace_data, handle_change)

      {:error, reason} ->
        if rate_limited_reason?(reason) do
          :ok
        else
          Logger.warning(
            "Marketplace fetch failed for user_id #{creator.tiktok_user_id}: #{inspect(reason)}"
          )

          # Fall back to username search if user_id lookup fails
          enrich_creator_by_username(brand_id, creator)
        end

        {:error, reason}
    end
  end

  # Enrich using username search (original method)
  defp enrich_creator_by_username(brand_id, creator) do
    username = creator.tiktok_username

    case TiktokShop.search_marketplace_creators(brand_id, keyword: username) do
      {:ok, %{creators: creators}} ->
        # Find exact match by username
        case find_exact_match(creators, username) do
          nil ->
            Logger.debug("No marketplace match for @#{username}")
            {:error, :not_found}

          marketplace_creator ->
            update_creator_from_marketplace(brand_id, creator, marketplace_creator, nil)
        end

      {:error, reason} ->
        if rate_limited_reason?(reason) do
          :ok
        else
          Logger.warning("Marketplace search failed for @#{username}: #{inspect(reason)}")
        end

        {:error, reason}
    end
  end

  # Detect if the creator's TikTok handle has changed
  defp detect_handle_change(_creator, nil), do: nil
  defp detect_handle_change(_creator, ""), do: nil

  defp detect_handle_change(creator, current_username) do
    stored_username = creator.tiktok_username
    normalized_current = String.downcase(String.trim(current_username))

    normalized_stored =
      if stored_username, do: String.downcase(String.trim(stored_username)), else: nil

    if normalized_stored && normalized_current != normalized_stored do
      Logger.info(
        "[HandleChange] Creator #{creator.id} changed handle: @#{stored_username} -> @#{current_username}"
      )

      %{
        old_username: stored_username,
        new_username: current_username
      }
    else
      nil
    end
  end

  defp find_exact_match(creators, username) do
    normalized_username = String.downcase(username)

    Enum.find(creators, fn c ->
      c_username = c["username"] || ""
      String.downcase(c_username) == normalized_username
    end)
  end

  defp update_creator_from_marketplace(brand_id, creator, marketplace_data, handle_change) do
    # Extract metrics from marketplace response
    avatar_url = get_in(marketplace_data, ["avatar", "url"])

    # Parse current GMV values from API
    current_gmv = parse_gmv_cents(marketplace_data["gmv"])
    current_video_gmv = parse_gmv_cents(marketplace_data["video_gmv"])
    current_live_gmv = parse_gmv_cents(marketplace_data["live_gmv"])

    # Calculate cumulative GMV and deltas
    {cumulative_attrs, deltas} =
      calculate_cumulative_gmv(creator, current_gmv, current_video_gmv, current_live_gmv)

    attrs =
      %{
        follower_count: marketplace_data["follower_count"],
        tiktok_nickname: marketplace_data["nickname"],
        tiktok_avatar_url: avatar_url,
        last_enriched_at: DateTime.utc_now(),
        enrichment_source: "marketplace_api"
      }
      |> maybe_put_avatar_storage_key(creator, avatar_url)
      |> maybe_put_gmv(marketplace_data)
      |> maybe_put_video_gmv(marketplace_data)
      |> maybe_put_avg_views(marketplace_data)
      |> maybe_put_handle_change(creator, handle_change)
      |> Map.merge(cumulative_attrs)

    case Creators.update_creator(creator, attrs) do
      {:ok, updated_creator} ->
        # Also create a performance snapshot for historical tracking
        create_enrichment_snapshot(brand_id, updated_creator, marketplace_data, deltas)

        username_display = updated_creator.tiktok_username || creator.tiktok_username

        Logger.debug(
          "Enriched @#{username_display}: #{attrs[:follower_count]} followers, $#{(attrs[:total_gmv_cents] || 0) / 100} GMV (cumulative: $#{(attrs[:cumulative_gmv_cents] || 0) / 100})"
        )

        {:ok, updated_creator}

      {:error, changeset} ->
        Logger.warning(
          "Failed to update creator @#{creator.tiktok_username}: #{inspect(changeset.errors)}"
        )

        {:error, :update_failed}
    end
  end

  # Calculate cumulative GMV using delta accumulation
  # Returns {cumulative_attrs, deltas} where:
  # - cumulative_attrs: map of cumulative fields to update on creator
  # - deltas: map of delta values to store on snapshot
  defp calculate_cumulative_gmv(creator, current_gmv, current_video_gmv, current_live_gmv) do
    if is_nil(creator.gmv_tracking_started_at) do
      build_baseline_gmv(current_gmv, current_video_gmv, current_live_gmv)
    else
      build_delta_gmv(creator, current_gmv, current_video_gmv, current_live_gmv)
    end
  end

  # First enrichment - establish baseline
  defp build_baseline_gmv(current_gmv, current_video_gmv, current_live_gmv) do
    gmv = current_gmv || 0
    video_gmv = current_video_gmv || 0
    live_gmv = current_live_gmv || 0

    {
      %{
        gmv_tracking_started_at: Date.utc_today(),
        cumulative_gmv_cents: gmv,
        cumulative_video_gmv_cents: video_gmv,
        cumulative_live_gmv_cents: live_gmv
      },
      %{gmv_delta_cents: gmv, video_gmv_delta_cents: video_gmv, live_gmv_delta_cents: live_gmv}
    }
  end

  # Subsequent enrichment - calculate deltas (delta = max(0, current - previous) to handle rolloff)
  defp build_delta_gmv(creator, current_gmv, current_video_gmv, current_live_gmv) do
    gmv_delta = calculate_delta(current_gmv, creator.total_gmv_cents)
    video_gmv_delta = calculate_delta(current_video_gmv, creator.video_gmv_cents)
    live_gmv_delta = calculate_delta(current_live_gmv, creator.live_gmv_cents)

    {
      %{
        cumulative_gmv_cents: (creator.cumulative_gmv_cents || 0) + gmv_delta,
        cumulative_video_gmv_cents: (creator.cumulative_video_gmv_cents || 0) + video_gmv_delta,
        cumulative_live_gmv_cents: (creator.cumulative_live_gmv_cents || 0) + live_gmv_delta
      },
      %{
        gmv_delta_cents: gmv_delta,
        video_gmv_delta_cents: video_gmv_delta,
        live_gmv_delta_cents: live_gmv_delta
      }
    }
  end

  # Calculate delta with floor at 0 (when rolloff exceeds new sales, delta = 0)
  defp calculate_delta(nil, _previous), do: 0
  defp calculate_delta(_current, nil), do: 0
  defp calculate_delta(current, previous), do: max(0, current - previous)

  # Parse GMV from API response format
  defp parse_gmv_cents(%{"amount" => amount, "currency" => "USD"}) when is_binary(amount) do
    {dollars, _} = Float.parse(amount)
    round(dollars * 100)
  end

  defp parse_gmv_cents(_), do: nil

  # Apply handle change: update username and preserve old one in history
  defp maybe_put_handle_change(attrs, _creator, nil), do: attrs

  defp maybe_put_handle_change(attrs, creator, %{
         old_username: old_username,
         new_username: new_username
       }) do
    # Get existing previous usernames, add the old one if not already present
    previous = creator.previous_tiktok_usernames || []
    normalized_old = String.downcase(String.trim(old_username))

    updated_previous =
      if normalized_old in Enum.map(previous, &String.downcase/1) do
        previous
      else
        previous ++ [old_username]
      end

    attrs
    |> Map.put(:tiktok_username, new_username)
    |> Map.put(:previous_tiktok_usernames, updated_previous)
  end

  defp maybe_put_avatar_storage_key(attrs, creator, avatar_url) do
    case maybe_store_creator_avatar(creator, avatar_url) do
      {:ok, key} ->
        Map.put(attrs, :tiktok_avatar_storage_key, key)

      :skip ->
        attrs

      {:error, reason} ->
        Logger.warning(
          "Failed to store avatar for creator @#{creator.tiktok_username}: #{inspect(reason)}"
        )

        attrs
    end
  end

  defp maybe_put_gmv(attrs, %{"gmv" => %{"amount" => amount, "currency" => "USD"}})
       when is_binary(amount) do
    {gmv_dollars, _} = Float.parse(amount)
    Map.put(attrs, :total_gmv_cents, round(gmv_dollars * 100))
  end

  defp maybe_put_gmv(attrs, _marketplace_data), do: attrs

  defp maybe_put_video_gmv(attrs, %{"video_gmv" => %{"amount" => amount, "currency" => "USD"}})
       when is_binary(amount) do
    {gmv_dollars, _} = Float.parse(amount)
    Map.put(attrs, :video_gmv_cents, round(gmv_dollars * 100))
  end

  defp maybe_put_video_gmv(attrs, _marketplace_data), do: attrs

  defp maybe_put_avg_views(attrs, %{"avg_ec_video_view_count" => avg_views})
       when not is_nil(avg_views) do
    Map.put(attrs, :avg_video_views, avg_views)
  end

  defp maybe_put_avg_views(attrs, _marketplace_data), do: attrs

  defp maybe_store_creator_avatar(_creator, nil), do: :skip
  defp maybe_store_creator_avatar(_creator, ""), do: :skip

  defp maybe_store_creator_avatar(creator, avatar_url) do
    SocialObjects.Storage.store_creator_avatar(avatar_url, creator.id)
  end

  defp create_enrichment_snapshot(brand_id, creator, marketplace_data, deltas) do
    # Create a performance snapshot for historical tracking
    attrs = %{
      creator_id: creator.id,
      snapshot_date: Date.utc_today(),
      source: "tiktok_marketplace",
      follower_count: marketplace_data["follower_count"],
      avg_video_views: marketplace_data["avg_ec_video_view_count"]
    }

    # Add GMV fields if available
    attrs =
      attrs
      |> maybe_put_gmv_field(:gmv_cents, marketplace_data["gmv"])
      |> maybe_put_gmv_field(:video_gmv_cents, marketplace_data["video_gmv"])
      |> maybe_put_gmv_field(:live_gmv_cents, marketplace_data["live_gmv"])

    # Add delta fields for audit trail
    attrs = Map.merge(attrs, deltas)

    case Creators.create_performance_snapshot(brand_id, attrs) do
      {:ok, _snapshot} -> :ok
      # Snapshot creation failure shouldn't fail enrichment
      {:error, _} -> :ok
    end
  end

  defp maybe_put_gmv_field(attrs, field, %{"amount" => amount, "currency" => "USD"})
       when is_binary(amount) do
    {dollars, _} = Float.parse(amount)
    Map.put(attrs, field, round(dollars * 100))
  end

  defp maybe_put_gmv_field(attrs, _field, _), do: attrs
end
