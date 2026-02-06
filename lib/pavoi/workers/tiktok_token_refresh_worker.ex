defmodule Pavoi.Workers.TiktokTokenRefreshWorker do
  @moduledoc """
  Oban worker that proactively refreshes TikTok Shop access tokens before they expire.

  Runs every 30 minutes via cron to ensure tokens are always fresh.
  This prevents 401 Expired credentials errors during product syncs.

  ## Token Lifecycle

  - Access tokens: Typically expire in 4-24 hours
  - Refresh tokens: Typically expire in 6-12 months (requires re-authorization)

  This worker handles access token refresh. If the refresh token expires,
  the user must re-authorize via the TikTok OAuth flow.
  """

  use Oban.Worker,
    queue: :tiktok,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing]]

  require Logger
  alias Pavoi.TiktokShop

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case resolve_brand_id(Map.get(args, "brand_id")) do
      {:ok, brand_id} ->
        case TiktokShop.maybe_refresh_token_if_expiring(brand_id) do
          {:ok, :no_refresh_needed} ->
            Logger.debug("TikTok token still valid, no refresh needed")
            :ok

          {:ok, :refreshed} ->
            Logger.info("TikTok access token refreshed successfully")
            :ok

          {:error, :no_auth_record} ->
            Logger.debug("No TikTok auth record found, skipping token refresh")
            :ok

          {:error, reason} ->
            Logger.error("Failed to refresh TikTok token: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("[TiktokTokenRefresh] Failed to resolve brand_id: #{inspect(reason)}")
        {:discard, reason}
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
end
