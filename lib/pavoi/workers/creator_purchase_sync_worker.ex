defmodule Pavoi.Workers.CreatorPurchaseSyncWorker do
  @moduledoc """
  Syncs orders placed BY creators from the TikTok Orders API.

  This worker:
  1. Gets all creators with a tiktok_user_id
  2. Queries the Orders API for orders where user_id matches
  3. Stores matching orders in creator_purchases table
  4. Detects sample fulfillment (when a creator buys a product they sampled)

  Run manually: Oban.insert(Pavoi.Workers.CreatorPurchaseSyncWorker.new(%{}))
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing]]

  require Logger
  import Ecto.Query

  alias Pavoi.Creators
  alias Pavoi.Creators.Creator
  alias Pavoi.Repo
  alias Pavoi.TiktokShop

  @batch_size 100
  @api_delay_ms 300

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"brand_id" => brand_id}}) do
    brand_id = normalize_brand_id(brand_id)
    Logger.info("[CreatorPurchaseSync] Starting sync...")

    # Build user_id -> creator_id lookup
    creator_lookup = build_creator_lookup(brand_id)
    creator_count = map_size(creator_lookup)

    if creator_count == 0 do
      Logger.info("[CreatorPurchaseSync] No creators with tiktok_user_id found, skipping")
      :ok
    else
      Logger.info("[CreatorPurchaseSync] Found #{creator_count} creators with tiktok_user_id")

      existing_order_ids = Creators.list_existing_purchase_order_ids(brand_id)
      Logger.info("[CreatorPurchaseSync] #{MapSet.size(existing_order_ids)} existing orders")

      {:ok, stats} = sync_orders(brand_id, creator_lookup, existing_order_ids)

      Logger.info(
        "[CreatorPurchaseSync] Complete - synced: #{stats.synced}, skipped: #{stats.skipped}, errors: #{stats.errors}"
      )

      :ok
    end
  end

  def perform(%Oban.Job{}) do
    Logger.error("[CreatorPurchaseSync] Missing brand_id in job args")
    {:discard, :missing_brand_id}
  end

  defp build_creator_lookup(brand_id) do
    from(c in Creator,
      join: bc in Pavoi.Creators.BrandCreator,
      on: bc.creator_id == c.id,
      where: bc.brand_id == ^brand_id and not is_nil(c.tiktok_user_id),
      select: {c.tiktok_user_id, c.id}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp sync_orders(brand_id, creator_lookup, existing_ids) do
    # Paginate through all orders (no time filter, limited pages)
    initial_stats = %{synced: 0, skipped: 0, errors: 0, pages: 0}

    sync_orders_page(brand_id, nil, creator_lookup, existing_ids, initial_stats)
  end

  defp sync_orders_page(brand_id, page_token, creator_lookup, existing_ids, stats) do
    params = build_page_params(page_token)

    case TiktokShop.make_api_request(brand_id, :post, "/order/202309/orders/search", params, %{}) do
      {:ok, %{"data" => data}} ->
        Process.sleep(@api_delay_ms)
        new_stats = handle_orders_response(brand_id, data, creator_lookup, existing_ids, stats)

        maybe_fetch_next_page(
          brand_id,
          data["next_page_token"],
          creator_lookup,
          existing_ids,
          new_stats
        )

      {:error, reason} ->
        Logger.error("[CreatorPurchaseSync] API error: #{inspect(reason)}")
        {:ok, stats}
    end
  end

  defp build_page_params(nil), do: %{page_size: @batch_size}
  defp build_page_params(token), do: %{page_size: @batch_size, page_token: token}

  defp handle_orders_response(
         brand_id,
         %{"orders" => orders},
         creator_lookup,
         existing_ids,
         stats
       )
       when is_list(orders) do
    stats = process_orders_batch(brand_id, orders, creator_lookup, existing_ids, stats)
    %{stats | pages: stats.pages + 1}
  end

  defp handle_orders_response(_brand_id, _data, _creator_lookup, _existing_ids, stats) do
    %{stats | pages: stats.pages + 1}
  end

  defp maybe_fetch_next_page(brand_id, token, creator_lookup, existing_ids, stats)
       when is_binary(token) and token != "" and stats.pages < 50 do
    sync_orders_page(brand_id, token, creator_lookup, existing_ids, stats)
  end

  defp maybe_fetch_next_page(_brand_id, _token, _creator_lookup, _existing_ids, stats) do
    {:ok, stats}
  end

  defp process_orders_batch(brand_id, orders, creator_lookup, existing_ids, stats) do
    Enum.reduce(orders, stats, fn order, acc ->
      process_single_order(brand_id, order, creator_lookup, existing_ids, acc)
    end)
  end

  defp process_single_order(brand_id, order, creator_lookup, existing_ids, stats) do
    user_id = order["user_id"]
    order_id = order["id"]

    cond do
      MapSet.member?(existing_ids, order_id) ->
        %{stats | skipped: stats.skipped + 1}

      !Map.has_key?(creator_lookup, user_id) ->
        %{stats | skipped: stats.skipped + 1}

      true ->
        sync_creator_order(brand_id, order, Map.get(creator_lookup, user_id), stats)
    end
  end

  defp sync_creator_order(brand_id, order, creator_id, stats) do
    case create_purchase(brand_id, order, creator_id) do
      {:ok, _} ->
        %{stats | synced: stats.synced + 1}

      {:error, reason} ->
        Logger.warning("[CreatorPurchaseSync] Error creating purchase: #{inspect(reason)}")
        %{stats | errors: stats.errors + 1}
    end
  end

  defp create_purchase(brand_id, order, creator_id) do
    total_cents = parse_money(order["payment"])
    ordered_at = parse_timestamp(order["create_time"])
    is_sample = order["is_sample_order"] == true

    line_items =
      (order["line_items"] || [])
      |> Enum.map(fn item ->
        %{
          "product_id" => item["product_id"],
          "product_name" => item["product_name"],
          "sku_id" => item["sku_id"],
          "sku_name" => item["sku_name"],
          "quantity" => 1,
          "sale_price_cents" => parse_item_price(item["sale_price"])
        }
      end)

    Creators.create_purchase(brand_id, %{
      creator_id: creator_id,
      tiktok_order_id: order["id"],
      order_status: order["status"],
      ordered_at: ordered_at,
      total_amount_cents: total_cents,
      currency: get_in(order, ["payment", "currency"]) || "USD",
      line_items: line_items,
      is_sample_order: is_sample
    })
  end

  defp parse_money(nil), do: 0

  defp parse_money(%{"total_amount" => amount}) when is_binary(amount) do
    case Float.parse(amount) do
      {val, _} -> round(val * 100)
      :error -> 0
    end
  end

  defp parse_money(_), do: 0

  defp parse_item_price(nil), do: 0

  defp parse_item_price(amount) when is_binary(amount) do
    case Float.parse(amount) do
      {val, _} -> round(val * 100)
      :error -> 0
    end
  end

  defp parse_item_price(_), do: 0

  defp parse_timestamp(nil), do: nil
  defp parse_timestamp(unix) when is_integer(unix), do: DateTime.from_unix!(unix)
  defp parse_timestamp(_), do: nil

  defp normalize_brand_id(brand_id) when is_integer(brand_id), do: brand_id

  defp normalize_brand_id(brand_id) when is_binary(brand_id) do
    String.to_integer(brand_id)
  end
end
