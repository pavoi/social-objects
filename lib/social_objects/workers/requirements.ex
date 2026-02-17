defmodule SocialObjects.Workers.Requirements do
  @moduledoc """
  Single source of truth for worker prerequisites.

  This module provides a unified gate function used by both the cron scheduler
  and manual trigger UI. It ensures consistent behavior across all entry points.

  ## Design Principles

  1. **Single gate function** - Both cron scheduler and manual trigger use the same `can_run?/2`
  2. **Brand capability snapshot** - Compute all config checks once per brand, avoid N+1
  3. **Hard vs soft requirements** - Explicit modeling of blocking vs no-op behavior
  4. **Fail closed** - Unknown workers/requirements block execution and surface clear errors

  ## Requirement Types

  - `{:hard, capability}` - Blocks execution if missing. Job will not be enqueued.
  - `{:soft, capability}` - Allows job to run, but may no-op gracefully if missing.

  ## Freshness Modes

  - `:scheduled` - Default 24h staleness threshold for scheduled workers
  - `:weekly` - Default 192h (8 days) staleness threshold for weekly workers
  - `:on_demand` - No staleness indicator shown (triggered manually or by events)
  """

  alias SocialObjects.Settings
  alias SocialObjects.TiktokShop
  alias SocialObjects.Workers.Registry

  @type requirement :: {:hard, capability()} | {:soft, capability()}
  @type capability :: :tiktok_auth | :shopify | :bigquery | :live_accounts
  @type worker_def :: %{optional(atom()) => any(), requirements: [requirement()], key: atom()}

  @all_capabilities [:tiktok_auth, :shopify, :bigquery, :live_accounts]

  @requirement_labels %{
    tiktok_auth: "TikTok Shop auth",
    shopify: "Shopify credentials",
    bigquery: "BigQuery credentials",
    live_accounts: "TikTok live accounts"
  }

  @freshness_mode_defaults %{
    scheduled: 24,
    weekly: 192,
    on_demand: nil
  }

  @doc """
  Computes a snapshot of brand capabilities for all requirement checks.

  Call this once per brand and reuse for all worker evaluations to avoid N+1 queries.

  ## Example

      capabilities = Requirements.get_brand_capabilities(brand_id)
      # => %{tiktok_auth: true, shopify: false, bigquery: true, live_accounts: true}
  """
  @spec get_brand_capabilities(pos_integer()) :: %{
          tiktok_auth: boolean(),
          shopify: boolean(),
          bigquery: boolean(),
          live_accounts: boolean()
        }
  def get_brand_capabilities(brand_id) do
    get_brand_capabilities(brand_id, @all_capabilities)
  end

  @doc """
  Computes a capability snapshot scoped to only the requested capabilities.

  The second argument accepts either:
  - a list of capability atoms (e.g. `[:tiktok_auth, :shopify]`)
  - a worker requirements list (e.g. `[hard: :tiktok_auth, soft: :shopify]`)

  This is useful for high-volume cron evaluation where we only need a subset
  of capabilities for a specific worker.
  """
  @spec get_brand_capabilities(pos_integer(), [capability() | requirement()]) :: %{
          optional(capability()) => boolean()
        }
  def get_brand_capabilities(brand_id, required_caps) when is_list(required_caps) do
    required_caps
    |> normalize_capabilities()
    |> Enum.into(%{}, fn cap ->
      {cap, configured?(brand_id, cap)}
    end)
  end

  @doc """
  Single gate function used by BOTH cron scheduler and manual trigger.

  Returns `{:ok, :ready}` when all hard requirements are met, or an error tuple
  describing what's missing.

  ## Parameters

  - `worker_key` - The atom key identifying the worker (e.g., `:tiktok_sync`)
  - `brand_id_or_capabilities` - Either a brand ID (will fetch capabilities) or
    a pre-computed capabilities map from `get_brand_capabilities/1`

  ## Returns

  - `{:ok, :ready}` - All hard requirements met, safe to enqueue
  - `{:error, :missing_hard, [capability]}` - Hard requirements not met
  - `{:error, :unknown_worker}` - Worker key not found in registry

  ## Examples

      # With brand_id (fetches capabilities)
      case Requirements.can_run?(:tiktok_sync, brand_id) do
        {:ok, :ready} -> enqueue_job(...)
        {:error, :missing_hard, missing} -> Logger.debug("Skipping: \#{inspect(missing)}")
        {:error, :unknown_worker} -> Logger.error("Unknown worker")
      end

      # With pre-computed capabilities (more efficient for batch operations)
      capabilities = Requirements.get_brand_capabilities(brand_id)
      Requirements.can_run?(:tiktok_sync, capabilities)
  """
  @spec can_run?(atom() | worker_def(), pos_integer() | map()) ::
          {:ok, :ready} | {:error, :missing_hard, [atom()]} | {:error, :unknown_worker}
  def can_run?(%{requirements: requirements} = worker, brand_id) when is_integer(brand_id) do
    capabilities = get_brand_capabilities(brand_id, requirements)
    can_run?(worker, capabilities)
  end

  def can_run?(%{requirements: requirements}, capabilities) when is_map(capabilities) do
    missing_hard = find_missing_requirements(requirements, capabilities, :hard)

    if missing_hard == [] do
      {:ok, :ready}
    else
      {:error, :missing_hard, missing_hard}
    end
  end

  def can_run?(worker_key, brand_id) when is_integer(brand_id) do
    case Registry.get_worker(worker_key) do
      nil -> {:error, :unknown_worker}
      worker -> can_run?(worker, brand_id)
    end
  end

  def can_run?(worker_key, capabilities) when is_map(capabilities) do
    case Registry.get_worker(worker_key) do
      nil ->
        {:error, :unknown_worker}

      worker ->
        can_run?(worker, capabilities)
    end
  end

  @doc """
  Returns all missing requirements (hard and soft) for UI display.

  This is useful for showing the user exactly what's missing and why
  a worker might be disabled or running in a degraded mode.

  ## Example

      missing = Requirements.missing_requirements(:tiktok_sync, capabilities)
      # => %{hard: [:tiktok_auth], soft: []}
  """
  @spec missing_requirements(atom(), map()) :: %{hard: [atom()], soft: [atom()]}
  def missing_requirements(worker_key, capabilities) when is_map(capabilities) do
    case Registry.get_worker(worker_key) do
      nil ->
        %{hard: [], soft: []}

      worker ->
        requirements = Map.get(worker, :requirements, [])

        %{
          hard: find_missing_requirements(requirements, capabilities, :hard),
          soft: find_missing_requirements(requirements, capabilities, :soft)
        }
    end
  end

  @doc """
  Converts a list of capability atoms to human-readable labels.

  ## Example

      Requirements.requirement_labels([:tiktok_auth, :shopify])
      # => ["TikTok Shop auth", "Shopify credentials"]
  """
  @spec requirement_labels([atom()]) :: [String.t()]
  def requirement_labels(capabilities) when is_list(capabilities) do
    Enum.map(capabilities, fn cap ->
      Map.get(@requirement_labels, cap, to_string(cap))
    end)
  end

  @doc """
  Gets the human-readable label for a single capability.

  ## Example

      Requirements.requirement_label(:tiktok_auth)
      # => "TikTok Shop auth"
  """
  @spec requirement_label(atom()) :: String.t()
  def requirement_label(capability) do
    Map.get(@requirement_labels, capability, to_string(capability))
  end

  @doc """
  Returns the default staleness hours for a given freshness mode.

  ## Examples

      Requirements.default_staleness_hours(:scheduled)  # => 24
      Requirements.default_staleness_hours(:weekly)     # => 192
      Requirements.default_staleness_hours(:on_demand)  # => nil
  """
  @spec default_staleness_hours(atom()) :: pos_integer() | nil
  def default_staleness_hours(mode) do
    Map.get(@freshness_mode_defaults, mode)
  end

  @doc """
  Returns the effective max staleness hours for a worker.

  Uses the worker's explicit `max_staleness_hours` if set, otherwise falls back
  to the default for the worker's `freshness_mode`.

  ## Example

      # Worker with freshness_mode: :scheduled and no override -> 24
      # Worker with max_staleness_hours: 48 -> 48
      # Worker with freshness_mode: :on_demand -> nil
  """
  @spec effective_staleness_hours(map()) :: pos_integer() | nil
  def effective_staleness_hours(worker) do
    case Map.get(worker, :max_staleness_hours) do
      nil ->
        mode = Map.get(worker, :freshness_mode, :scheduled)
        default_staleness_hours(mode)

      hours ->
        hours
    end
  end

  @doc """
  Computes worker requirements info for all workers given brand capabilities.

  Returns a map of worker_key => requirement_info for use in the UI.

  ## Example

      worker_reqs = Requirements.compute_all_worker_requirements(capabilities)
      # => %{
      #   tiktok_sync: %{can_run: true, missing_hard: [], missing_soft: []},
      #   shopify_sync: %{can_run: false, missing_hard: [:shopify], missing_soft: []},
      #   ...
      # }
  """
  @spec compute_all_worker_requirements(map()) :: %{atom() => map()}
  def compute_all_worker_requirements(capabilities) when is_map(capabilities) do
    Registry.all_workers()
    |> Enum.map(fn worker ->
      missing = missing_requirements(worker.key, capabilities)

      {worker.key,
       %{
         can_run: missing.hard == [],
         missing_hard: missing.hard,
         missing_soft: missing.soft,
         missing_hard_labels: requirement_labels(missing.hard),
         missing_soft_labels: requirement_labels(missing.soft)
       }}
    end)
    |> Map.new()
  end

  # Private helpers

  defp normalize_capabilities(items) do
    items
    |> Enum.flat_map(fn
      {_, cap} when is_atom(cap) -> [cap]
      cap when is_atom(cap) -> [cap]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp configured?(brand_id, :tiktok_auth), do: TiktokShop.get_auth(brand_id) != nil
  defp configured?(brand_id, :shopify), do: Settings.shopify_configured?(brand_id)
  defp configured?(brand_id, :bigquery), do: Settings.bigquery_configured?(brand_id)

  defp configured?(brand_id, :live_accounts),
    do: Settings.tiktok_live_accounts_configured?(brand_id)

  defp configured?(_brand_id, _unknown_capability), do: false

  defp find_missing_requirements(requirements, capabilities, requirement_type) do
    requirements
    |> Enum.filter(fn {type, _cap} -> type == requirement_type end)
    |> Enum.map(fn {_type, cap} -> cap end)
    |> Enum.reject(fn cap -> Map.get(capabilities, cap, false) end)
  end
end
