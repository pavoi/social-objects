defmodule Pavoi.TiktokShop.AnalyticsCache do
  @moduledoc """
  ETS-based cache for TikTok Shop Analytics API responses.

  Caches shop performance data with a 1-hour TTL to reduce API calls
  and improve dashboard page load times.
  """

  use GenServer

  @table :shop_analytics_cache
  @ttl_ms :timer.hours(1)

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Fetches cached data or calls the provided function to populate the cache.

  Falls back to calling fetch_fn directly if the cache table doesn't exist.

  ## Examples

      fetch({brand_id, "shop_performance", "30d"}, fn ->
        Analytics.get_shop_performance(brand_id, opts)
      end)
  """
  def fetch(key, fetch_fn) do
    if table_exists?() do
      fetch_with_cache(key, fetch_fn)
    else
      # Table doesn't exist yet, call function directly
      fetch_fn.()
    end
  end

  defp fetch_with_cache(key, fetch_fn) do
    case get(key) do
      {:ok, data} ->
        {:ok, data}

      :miss ->
        fetch_and_cache(key, fetch_fn)
    end
  end

  defp fetch_and_cache(key, fetch_fn) do
    case fetch_fn.() do
      {:ok, data} = result ->
        put(key, data)
        result

      error ->
        error
    end
  end

  @doc """
  Gets a value from the cache. Returns {:ok, value} or :miss.
  """
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, value}
        else
          :ets.delete(@table, key)
          :miss
        end

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc """
  Puts a value in the cache with TTL.
  """
  def put(key, value) do
    expires_at = System.monotonic_time(:millisecond) + @ttl_ms
    :ets.insert(@table, {key, value, expires_at})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Invalidates cache entries for a specific brand.
  """
  def invalidate_brand(brand_id) do
    if table_exists?() do
      :ets.match_delete(@table, {{brand_id, :_, :_}, :_, :_})
    end

    :ok
  end

  defp table_exists? do
    :ets.whereis(@table) != :undefined
  end

  # Server callbacks

  @impl true
  def init(_) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, :timer.minutes(10))
  end

  defp cleanup_expired do
    now = System.monotonic_time(:millisecond)

    :ets.foldl(
      fn {key, _value, expires_at}, acc ->
        if now >= expires_at, do: :ets.delete(@table, key)
        acc
      end,
      :ok,
      @table
    )
  end
end
