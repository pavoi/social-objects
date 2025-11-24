defmodule Pavoi.Shopify.Auth do
  @moduledoc """
  Handles Shopify authentication using the Client Credentials OAuth 2.0 grant.

  ## Dev Dashboard Apps (New Standard as of January 2026)

  This module implements authentication for Shopify apps created through the
  Dev Dashboard, which replaced the legacy "Custom Apps" approach. Starting
  January 1, 2026, you cannot create new legacy custom apps.

  ## How It Works

  1. App is created in Dev Dashboard (https://partners.shopify.com)
  2. App must be installed on your store through Dev Dashboard > Install app
  3. This module exchanges the app's client ID + client secret for an access token
  4. Tokens are valid for 24 hours and auto-refresh on 401 errors

  ## Important Configuration

  Required environment variables:
  - `SHOPIFY_CLIENT_ID` - From Dev Dashboard app settings
  - `SHOPIFY_CLIENT_SECRET` - From Dev Dashboard app settings
  - `SHOPIFY_STORE_NAME` - Your store name (e.g., "pavoipearls")

  Note: `SHOPIFY_ACCESS_TOKEN` is NOT needed - tokens are generated dynamically.

  ## Token Management

  Tokens are stored in Application config (in-memory) and refreshed on-demand
  when API requests return 401 Unauthorized errors. See `Pavoi.Shopify.Client`
  for the automatic retry logic.
  """

  require Logger

  @doc """
  Gets a valid Shopify Admin API access token.

  If a token is already stored in Application config, returns it.
  Otherwise, requests a new token from Shopify using client credentials.

  ## Returns

    - `{:ok, token}` - Valid access token
    - `{:error, reason}` - Failed to acquire token

  ## Examples

      iex> Pavoi.Shopify.Auth.get_access_token()
      {:ok, "shpat_..."}
  """
  def get_access_token do
    case Application.get_env(:pavoi, :shopify_access_token) do
      nil ->
        Logger.info("No access token cached, acquiring new token from Shopify...")
        refresh_access_token()

      token ->
        {:ok, token}
    end
  end

  @doc """
  Refreshes the Shopify Admin API access token using client credentials grant.

  Makes a request to Shopify's token endpoint with the app's client ID and
  client secret. The new token is stored in Application config and returned.

  ## Returns

    - `{:ok, token}` - New access token acquired and stored
    - `{:error, reason}` - Failed to acquire token

  ## Examples

      iex> Pavoi.Shopify.Auth.refresh_access_token()
      {:ok, "shpat_..."}
  """
  def refresh_access_token do
    Logger.info("Refreshing Shopify access token using client credentials grant...")

    client_id = Application.fetch_env!(:pavoi, :shopify_client_id)
    client_secret = Application.fetch_env!(:pavoi, :shopify_client_secret)
    shop_name = Application.fetch_env!(:pavoi, :shopify_store_name)

    url = "https://#{shop_name}.myshopify.com/admin/oauth/access_token"

    body = %{
      "grant_type" => "client_credentials",
      "client_id" => client_id,
      "client_secret" => client_secret
    }

    headers = [{"Content-Type", "application/x-www-form-urlencoded"}]

    # Convert body to form-encoded format
    form_body = URI.encode_query(body)

    result = Req.post(url, headers: headers, body: form_body)

    case result do
      {:ok, %{status: 200, body: %{"access_token" => token, "expires_in" => expires_in}}} ->
        Logger.info("✅ Successfully acquired Shopify access token (expires in #{expires_in}s)")

        # Store token in Application config
        Application.put_env(:pavoi, :shopify_access_token, token)

        {:ok, token}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Failed to acquire Shopify access token: HTTP #{status}")
        Logger.error("Response body: #{inspect(body)}")
        Logger.error("Hint: Ensure the app is installed on the store via Dev Dashboard > Install app")
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        Logger.error("HTTP request failed while acquiring token: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Clears the cached access token from Application config.

  This forces the next call to `get_access_token/0` to acquire a fresh token.
  Useful when a 401 error indicates the current token has expired.
  """
  def clear_token do
    Logger.debug("Clearing cached Shopify access token")
    Application.delete_env(:pavoi, :shopify_access_token)
  end
end
