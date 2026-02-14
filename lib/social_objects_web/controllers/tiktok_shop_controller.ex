defmodule SocialObjectsWeb.TiktokShopController do
  @moduledoc """
  Handles TikTok Shop OAuth callbacks and API operations.
  """
  use SocialObjectsWeb, :controller

  alias SocialObjects.TiktokShop
  import SocialObjectsWeb.ParamHelpers

  require Logger

  @doc """
  Initiates OAuth flow by storing brand_id in session and redirecting to TikTok.
  This is needed because TikTok Shop doesn't return the `state` parameter in callbacks.
  """
  def authorize(conn, %{"brand_id" => brand_id_param, "region" => region}) do
    case parse_id(brand_id_param) do
      {:ok, brand_id} ->
        auth_url = TiktokShop.generate_authorization_url(brand_id, region)

        Logger.info(
          "[TikTok OAuth] Starting OAuth flow for brand_id: #{brand_id}, region: #{region}"
        )

        conn
        |> put_session(:tiktok_oauth_brand_id, brand_id)
        |> redirect(external: auth_url)

      :error ->
        conn
        |> put_flash(:error, "Invalid brand ID")
        |> redirect(to: "/admin/brands")
    end
  end

  @doc """
  OAuth callback handler.
  Called when TikTok redirects back after user authorization.
  Exchanges the authorization code for access tokens and fetches shop information.

  Tries to get brand_id from:
  1. The `state` parameter (standard OAuth, if TikTok returns it)
  2. The session (fallback, since TikTok doesn't always return state)
  """
  def callback(conn, %{"code" => auth_code} = params) do
    Logger.info("[TikTok OAuth] Received callback with code")

    # Try to get brand_id from state first, then fall back to session
    brand_id = get_brand_id_from_state(params) || get_session(conn, :tiktok_oauth_brand_id)

    if is_nil(brand_id) do
      Logger.error("[TikTok OAuth] No brand_id found in state or session")

      conn
      |> delete_session(:tiktok_oauth_brand_id)
      |> put_flash(:error, "TikTok Shop connection failed: session expired. Please try again.")
      |> redirect(to: "/admin/brands")
    else
      Logger.info("[TikTok OAuth] Using brand_id: #{brand_id}")
      process_oauth_callback(conn, brand_id, auth_code)
    end
  end

  def callback(conn, params) do
    # If there's an error in the OAuth flow (no code parameter)
    Logger.warning("[TikTok OAuth] Callback without code. Params: #{inspect(Map.keys(params))}")
    error = Map.get(params, "error", "Unknown error")
    error_description = Map.get(params, "error_description", "No authorization code received")

    conn
    |> delete_session(:tiktok_oauth_brand_id)
    |> put_flash(:error, "TikTok Shop authorization error: #{error} - #{error_description}")
    |> redirect(to: "/admin/brands")
  end

  defp get_brand_id_from_state(%{"state" => state}) do
    case Phoenix.Token.verify(SocialObjectsWeb.Endpoint, "tiktok_oauth", state, max_age: 15 * 60) do
      {:ok, %{brand_id: brand_id}} ->
        Logger.info("[TikTok OAuth] Got brand_id from state parameter")
        brand_id

      {:error, reason} ->
        Logger.debug("[TikTok OAuth] State verification failed: #{inspect(reason)}")
        nil
    end
  end

  defp get_brand_id_from_state(_), do: nil

  defp process_oauth_callback(conn, brand_id, auth_code) do
    with {:ok, _auth} <- TiktokShop.exchange_code_for_token(brand_id, auth_code),
         _ <- Logger.info("[TikTok OAuth] Token exchange successful"),
         {:ok, auth} <- TiktokShop.get_authorized_shops(brand_id) do
      Logger.info(
        "[TikTok OAuth] Successfully connected to shop: #{auth.shop_name || auth.shop_id}"
      )

      conn
      |> delete_session(:tiktok_oauth_brand_id)
      |> put_flash(
        :info,
        "Successfully connected to TikTok Shop: #{auth.shop_name || auth.shop_id}"
      )
      |> redirect(to: "/admin/brands")
    else
      {:error, error} ->
        Logger.error("[TikTok OAuth] Connection failed: #{inspect(error)}")

        conn
        |> delete_session(:tiktok_oauth_brand_id)
        |> put_flash(:error, "TikTok Shop connection failed: #{inspect(error)}")
        |> redirect(to: "/admin/brands")
    end
  end

  @doc """
  Test endpoint to verify TikTok Shop API is working.
  Makes a simple API call to get shop information.
  """
  def test(conn, params) do
    brand_id = Map.get(params, "brand_id")

    case TiktokShop.make_api_request(brand_id, :get, "/authorization/202309/shops", %{}) do
      {:ok, response} ->
        json(conn, %{success: true, data: response})

      {:error, error} ->
        conn
        |> put_status(500)
        |> json(%{success: false, error: inspect(error)})
    end
  end
end
