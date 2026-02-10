defmodule Pavoi.TiktokShop do
  @moduledoc """
  The TiktokShop context handles TikTok Shop API authentication and operations.
  """

  import Ecto.Query, warn: false
  alias Pavoi.Repo
  alias Pavoi.TiktokShop.Auth

  # Configuration
  defp app_key, do: System.get_env("TTS_APP_KEY")
  defp app_secret, do: System.get_env("TTS_APP_SECRET")
  defp service_id, do: System.get_env("TTS_SERVICE_ID")
  defp region, do: System.get_env("TTS_REGION", "Global")
  defp auth_base, do: System.get_env("TTS_AUTH_BASE", "https://auth.tiktok-shops.com")
  defp api_base, do: System.get_env("TTS_API_BASE", "https://open-api.tiktokglobalshop.com")

  @doc """
  Generates an authorization URL for the user to approve the app.

  Returns the URL as a string that the user should visit in their browser.
  After authorization, they'll be redirected to the configured redirect_uri with an auth code.
  """
  def generate_authorization_url(brand_id) do
    # Determine the correct authorization base URL based on region
    auth_url_base =
      case region() do
        "US" -> "https://services.us.tiktokshop.com"
        _ -> "https://services.tiktokshop.com"
      end

    state = generate_state(brand_id)

    "#{auth_url_base}/open/authorize?service_id=#{service_id()}&state=#{state}"
  end

  @doc """
  Exchanges an authorization code for access and refresh tokens.

  This should be called in your OAuth callback handler after the user approves the app.
  Stores the tokens in the database and returns the auth record.
  """
  def exchange_code_for_token(brand_id, auth_code) do
    url = "#{auth_base()}/api/v2/token/get"

    params = [
      app_key: app_key(),
      app_secret: app_secret(),
      auth_code: auth_code,
      grant_type: "authorized_code"
    ]

    case Req.get(url, params: params) do
      {:ok, %Req.Response{status: 200, body: %{"data" => token_data}}} ->
        store_tokens(brand_id, token_data)

      {:ok, %Req.Response{status: 200, body: response}} ->
        {:error, "Token exchange failed: #{inspect(response)}"}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, error} ->
        {:error, "Request failed: #{inspect(error)}"}
    end
  end

  @doc """
  Refreshes the access token using the refresh token.

  Should be called when the access token expires.
  Updates the tokens in the database.
  """
  def refresh_access_token(brand_id) do
    case get_auth(brand_id) do
      nil ->
        {:error, :no_auth_record}

      auth ->
        url = "#{auth_base()}/api/v2/token/refresh"

        params = [
          app_key: app_key(),
          app_secret: app_secret(),
          refresh_token: auth.refresh_token,
          grant_type: "refresh_token"
        ]

        case Req.get(url, params: params) do
          {:ok, %Req.Response{status: 200, body: %{"data" => token_data}}} ->
            update_tokens(auth, token_data)

          {:ok, %Req.Response{status: 200, body: response}} ->
            {:error, "Token refresh failed: #{inspect(response)}"}

          {:ok, %Req.Response{status: status, body: body}} ->
            {:error, "HTTP #{status}: #{inspect(body)}"}

          {:error, error} ->
            {:error, "Request failed: #{inspect(error)}"}
        end
    end
  end

  @doc """
  Gets the authorized shops and extracts shop_id and shop_cipher.

  This should be called after obtaining an access token to get shop-specific credentials.
  Updates the auth record with shop information.
  """
  def get_authorized_shops(brand_id) do
    case get_auth(brand_id) do
      nil ->
        {:error, :no_auth_record}

      auth ->
        path = "/authorization/202309/shops"

        case make_api_request(brand_id, :get, path, %{}) do
          {:ok, %{"data" => %{"shops" => [_ | _] = shops}}} ->
            # Take the first shop
            shop = List.first(shops)

            attrs = %{
              shop_id: shop["id"],
              shop_cipher: shop["cipher"],
              shop_name: shop["name"],
              shop_code: shop["code"],
              region: shop["region"]
            }

            update_auth(auth, attrs)

          {:ok, %{"data" => %{"shops" => []}}} ->
            {:error, "No authorized shops found"}

          {:ok, response} ->
            {:error, "Unexpected response: #{inspect(response)}"}

          {:error, error} ->
            {:error, error}
        end
    end
  end

  @doc """
  Proactively refreshes the access token if it's expiring within 1 hour.

  Called by TiktokTokenRefreshWorker on a cron schedule to prevent token expiration.
  Returns:
    - `{:ok, :no_refresh_needed}` - Token is still valid
    - `{:ok, :refreshed}` - Token was refreshed successfully
    - `{:error, reason}` - Refresh failed or no auth record exists
  """
  def maybe_refresh_token_if_expiring(brand_id) do
    case get_auth(brand_id) do
      nil -> {:error, :no_auth_record}
      auth -> maybe_refresh_token(brand_id, auth)
    end
  end

  defp maybe_refresh_token(brand_id, auth) do
    if token_expiring_within?(auth, 60 * 60) do
      do_refresh_token(brand_id)
    else
      {:ok, :no_refresh_needed}
    end
  end

  defp token_expiring_within?(auth, seconds) do
    now = DateTime.utc_now()
    threshold = DateTime.add(now, seconds, :second)
    DateTime.compare(auth.access_token_expires_at, threshold) == :lt
  end

  defp do_refresh_token(brand_id) do
    case refresh_access_token(brand_id) do
      {:ok, _updated_auth} -> {:ok, :refreshed}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Makes an authenticated API request to TikTok Shop.

  Automatically handles signature generation and token refresh if needed.
  Will retry once on 401 expired credentials errors.
  """
  def make_api_request(brand_id, method, path, params \\ %{}, body \\ %{}) do
    do_make_api_request(brand_id, method, path, params, body, _retry_count = 0)
  end

  defp do_make_api_request(brand_id, method, path, params, body, retry_count) do
    result =
      with {:ok, auth} <- get_auth_or_error(brand_id),
           {:ok, auth} <- ensure_valid_token(brand_id, auth),
           {all_params, body_string, headers} <- build_request_params(auth, path, params, body),
           url <- "#{api_base()}#{path}" do
        execute_request(method, url, all_params, body_string, headers)
      end

    maybe_retry_on_token_error(result, brand_id, method, path, params, body, retry_count)
  end

  defp maybe_retry_on_token_error(
         {:error, reason} = result,
         brand_id,
         method,
         path,
         params,
         body,
         0
       )
       when is_binary(reason) do
    if token_expired_error?(reason) do
      retry_with_fresh_token(brand_id, method, path, params, body, result)
    else
      result
    end
  end

  defp maybe_retry_on_token_error(
         result,
         _brand_id,
         _method,
         _path,
         _params,
         _body,
         _retry_count
       ),
       do: result

  defp retry_with_fresh_token(brand_id, method, path, params, body, original_result) do
    case refresh_access_token(brand_id) do
      {:ok, _} -> do_make_api_request(brand_id, method, path, params, body, 1)
      {:error, _} -> original_result
    end
  end

  defp token_expired_error?(reason) do
    String.contains?(reason, "105002") or String.contains?(reason, "Expired credentials")
  end

  @doc """
  Generates HMAC-SHA256 signature for TikTok Shop API requests.

  The signature algorithm:
  1. Collect all parameters except 'sign' and 'access_token'
  2. Sort parameters alphabetically by key
  3. Concatenate as key1value1key2value2...
  4. Prepend the API path
  5. Append request body (if any)
  6. Wrap with app_secret at beginning and end
  7. Generate HMAC-SHA256 hash
  8. Convert to hexadecimal string
  """
  def generate_signature(path, params, body \\ "") do
    # Remove sign and access_token from params
    params =
      params
      |> Map.delete(:sign)
      |> Map.delete("sign")
      |> Map.delete(:access_token)
      |> Map.delete("access_token")

    # Sort parameters alphabetically and build string
    param_string =
      params
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map_join("", fn {k, v} -> "#{k}#{v}" end)

    # Build input string: secret + path + params + body + secret
    input = "#{app_secret()}#{path}#{param_string}#{body}#{app_secret()}"

    # Generate HMAC-SHA256
    :crypto.mac(:hmac, :sha256, app_secret(), input)
    |> Base.encode16(case: :lower)
  end

  ## Private Helper Functions

  defp get_auth_or_error(brand_id) do
    case get_auth(brand_id) do
      nil -> {:error, :no_auth_record}
      auth -> {:ok, auth}
    end
  end

  defp build_request_params(auth, path, params, body) do
    timestamp = :os.system_time(:second)

    # Build common parameters (WITHOUT access_token - it goes in header)
    common_params = %{
      app_key: app_key(),
      timestamp: timestamp
    }

    # Add shop_cipher if available, not already in params, and not an authorization endpoint
    # (authorization endpoints don't accept shop_cipher since that's what they return)
    common_params =
      if auth.shop_cipher && !Map.has_key?(params, :shop_cipher) &&
           !String.starts_with?(path, "/authorization") do
        Map.put(common_params, :shop_cipher, auth.shop_cipher)
      else
        common_params
      end

    # Merge with provided params
    all_params = Map.merge(common_params, params)

    # For signature, body needs to be JSON string
    body_string = if body == %{} or body == "", do: "", else: Jason.encode!(body)

    # Generate signature
    sign = generate_signature(path, all_params, body_string)
    all_params = Map.put(all_params, :sign, sign)

    # Build headers with access token and content-type
    # Note: Content-Type is required even for GET requests on some analytics endpoints
    headers = [
      {"Content-Type", "application/json"},
      {"x-tts-access-token", auth.access_token}
    ]

    {all_params, body_string, headers}
  end

  defp execute_request(:get, url, all_params, _body_string, headers) do
    execute_get_request(url, all_params, headers)
  end

  defp execute_request(:post, url, all_params, body_string, headers) do
    execute_post_request(url, all_params, body_string, headers)
  end

  defp execute_get_request(url, all_params, headers) do
    url
    |> Req.get(params: all_params, headers: headers)
    |> handle_response()
  end

  defp execute_post_request(url, all_params, body_string, headers) do
    # Build URL with query parameters manually
    query_string = URI.encode_query(all_params)
    full_url = "#{url}?#{query_string}"

    full_url
    |> Req.post(body: body_string, headers: headers)
    |> handle_response()
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: response_body}}) do
    {:ok, response_body}
  end

  defp handle_response({:ok, %Req.Response{status: 429, body: response_body}}) do
    {:error, {:rate_limited, response_body}}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: response_body}}) do
    {:error, "HTTP #{status}: #{inspect(response_body)}"}
  end

  defp handle_response({:error, error}) do
    {:error, "Request failed: #{inspect(error)}"}
  end

  defp generate_state(brand_id) do
    nonce = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    Phoenix.Token.sign(PavoiWeb.Endpoint, "tiktok_oauth", %{brand_id: brand_id, nonce: nonce})
  end

  # =============================================================================
  # Creator Marketplace API
  # =============================================================================

  @marketplace_creators_path "/affiliate_seller/202406/marketplace_creators"

  @doc """
  Searches for creators on the TikTok Marketplace.

  ## Options
    - keyword: Search term (username, nickname)
    - page_size: Number of results (must be 12 or 20, default: 12)
    - page_token: Token for pagination (from previous response)
    - gmv_ranges: List of GMV range filters (e.g., ["GMV_RANGE_10000_AND_ABOVE"])
    - units_sold_ranges: List of unit sold filters
    - follower_demographics: Map with age_ranges, count_range, gender_distribution

  ## Returns
    {:ok, %{creators: [...], next_page_token: "..."}} or {:error, reason}

  ## Examples
      # Search by username
      search_marketplace_creators(brand_id, keyword: "zoekate1")

      # Search high-GMV creators
      search_marketplace_creators(brand_id, gmv_ranges: ["GMV_RANGE_10000_AND_ABOVE"])
  """
  def search_marketplace_creators(brand_id, opts \\ []) do
    keyword = Keyword.get(opts, :keyword)
    page_size = Keyword.get(opts, :page_size, 12)
    page_token = Keyword.get(opts, :page_token)

    params = %{page_size: page_size}
    params = if page_token, do: Map.put(params, :page_token, page_token), else: params

    body = %{}
    body = if keyword, do: Map.put(body, "keyword", keyword), else: body
    body = maybe_add_filter(body, "gmv_ranges", Keyword.get(opts, :gmv_ranges))
    body = maybe_add_filter(body, "units_sold_ranges", Keyword.get(opts, :units_sold_ranges))

    body =
      maybe_add_filter(body, "follower_demographics", Keyword.get(opts, :follower_demographics))

    case make_api_request(brand_id, :post, "#{@marketplace_creators_path}/search", params, body) do
      {:ok, %{"code" => 0, "data" => data}} ->
        {:ok,
         %{
           creators: Map.get(data, "creators", []),
           next_page_token: Map.get(data, "next_page_token"),
           search_key: Map.get(data, "search_key")
         }}

      {:ok, %{"code" => code, "message" => message}} ->
        {:error, "API error [#{code}]: #{message}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets detailed performance data for a specific marketplace creator.

  ## Parameters
    - creator_user_id: The TikTok user ID of the creator

  ## Returns
    {:ok, creator_data} or {:error, reason}

  ## Notes
    - Rate limit: 10,000 requests per day
    - Only works for creators in the same region as the seller
    - Returns error 16901005 if creator doesn't have e-commerce permission
    - Returns error 16901006 if region doesn't match

  ## Example
      get_marketplace_creator(brand_id, "7494112116023331142")
  """
  def get_marketplace_creator(brand_id, creator_user_id) when is_binary(creator_user_id) do
    case make_api_request(
           brand_id,
           :get,
           "#{@marketplace_creators_path}/#{creator_user_id}",
           %{},
           %{}
         ) do
      {:ok, %{"code" => 0, "data" => data}} ->
        {:ok, data}

      {:ok, %{"code" => code, "message" => message}} ->
        {:error, "API error [#{code}]: #{message}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_add_filter(body, _key, nil), do: body
  defp maybe_add_filter(body, _key, []), do: body
  defp maybe_add_filter(body, key, value), do: Map.put(body, key, value)

  # =============================================================================
  # Orders API
  # =============================================================================

  @orders_search_path "/order/202309/orders/search"

  @doc """
  Fetches all orders within a time range.

  ## Parameters
    - start_time: DateTime for the start of the range (inclusive)
    - end_time: DateTime for the end of the range (exclusive)
    - opts: Additional options
      - page_size: Number of results per page (default: 100)

  ## Returns
    {:ok, [order]} - List of orders with payment info
    {:error, reason} - Error details

  ## Example
      # Get orders during a stream
      fetch_orders_in_range(brand_id, stream.started_at, stream.ended_at)
  """
  def fetch_orders_in_range(
        brand_id,
        %DateTime{} = start_time,
        %DateTime{} = end_time,
        opts \\ []
      ) do
    page_size = Keyword.get(opts, :page_size, 100)

    body = %{
      "create_time_ge" => DateTime.to_unix(start_time),
      "create_time_lt" => DateTime.to_unix(end_time)
    }

    fetch_all_orders_pages(brand_id, body, page_size, nil, [])
  end

  defp fetch_all_orders_pages(brand_id, body, page_size, page_token, acc) do
    params =
      if page_token,
        do: %{page_size: page_size, page_token: page_token},
        else: %{page_size: page_size}

    case make_api_request(brand_id, :post, @orders_search_path, params, body) do
      {:ok, %{"code" => 0, "data" => %{"orders" => orders} = data}} when is_list(orders) ->
        new_acc = acc ++ orders
        next_token = Map.get(data, "next_page_token")

        if next_token && next_token != "" && length(acc) < 1000 do
          # Rate limit protection
          Process.sleep(300)
          fetch_all_orders_pages(brand_id, body, page_size, next_token, new_acc)
        else
          {:ok, new_acc}
        end

      {:ok, %{"code" => 0, "data" => _}} ->
        # No orders field means empty result
        {:ok, acc}

      {:ok, %{"code" => code, "message" => message}} ->
        {:error, "API error [#{code}]: #{message}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Calculates hourly GMV from a list of orders.

  Groups orders by hour and sums the payment amounts.

  ## Returns
    A list of maps with :hour (DateTime truncated to hour) and :gmv_cents
  """
  def calculate_hourly_gmv(orders) when is_list(orders) do
    orders
    |> Enum.filter(&valid_order_for_gmv?/1)
    |> Enum.group_by(&order_hour/1)
    |> Enum.map(fn {hour, hour_orders} ->
      gmv_cents = Enum.reduce(hour_orders, 0, &sum_order_amount/2)
      %{hour: hour, gmv_cents: gmv_cents, order_count: length(hour_orders)}
    end)
    |> Enum.sort_by(& &1.hour, DateTime)
  end

  defp valid_order_for_gmv?(order) do
    # Include orders that aren't cancelled
    status = order["status"]
    status not in ["CANCELLED", "CANCEL"]
  end

  defp order_hour(order) do
    case order["create_time"] do
      unix when is_integer(unix) ->
        unix
        |> DateTime.from_unix!()
        |> DateTime.truncate(:second)
        |> Map.put(:minute, 0)
        |> Map.put(:second, 0)

      _ ->
        # Fallback for orders without timestamp
        DateTime.utc_now() |> Map.put(:minute, 0) |> Map.put(:second, 0)
    end
  end

  defp sum_order_amount(order, acc) do
    amount =
      case get_in(order, ["payment", "total_amount"]) do
        amount when is_binary(amount) ->
          case Float.parse(amount) do
            {val, _} -> round(val * 100)
            :error -> 0
          end

        _ ->
          0
      end

    acc + amount
  end

  # =============================================================================
  # Token Storage
  # =============================================================================

  defp store_tokens(brand_id, token_data) do
    access_expires_in = Map.get(token_data, "access_token_expire_in", 0)
    refresh_expires_in = Map.get(token_data, "refresh_token_expire_in", 0)

    attrs = %{
      access_token: token_data["access_token"],
      refresh_token: token_data["refresh_token"],
      access_token_expires_at: parse_expiration_time(access_expires_in),
      refresh_token_expires_at: parse_expiration_time(refresh_expires_in)
    }

    # Upsert: if record exists, update it; otherwise create new one
    case Repo.get_by(Auth, brand_id: brand_id) do
      nil ->
        %Auth{brand_id: brand_id}
        |> Auth.changeset(attrs)
        |> Repo.insert()

      existing_auth ->
        existing_auth
        |> Auth.changeset(attrs)
        |> Repo.update()
    end
  end

  defp update_tokens(auth, token_data) do
    access_expires_in = Map.get(token_data, "access_token_expire_in", 0)
    refresh_expires_in = Map.get(token_data, "refresh_token_expire_in", 0)

    attrs = %{
      access_token: token_data["access_token"],
      refresh_token: token_data["refresh_token"],
      access_token_expires_at: parse_expiration_time(access_expires_in),
      refresh_token_expires_at: parse_expiration_time(refresh_expires_in)
    }

    auth
    |> Auth.changeset(attrs)
    |> Repo.update()
  end

  # TikTok API can return expiration as either:
  # 1. Unix timestamp (e.g., 1765987200) - the actual expiration time
  # 2. Seconds until expiry (e.g., 86400) - duration to add to current time
  # We detect which by checking if the value is close to current Unix time
  defp parse_expiration_time(expires_value) when is_integer(expires_value) do
    now = DateTime.utc_now()
    now_unix = DateTime.to_unix(now)

    # 10 years in seconds - if value is within this range of current time, it's a timestamp
    ten_years = 315_360_000

    if expires_value > now_unix - ten_years and expires_value < now_unix + ten_years do
      # It's a Unix timestamp - convert directly
      DateTime.from_unix!(expires_value)
    else
      # It's seconds-until-expiry - add to current time
      DateTime.add(now, expires_value, :second)
    end
  end

  defp parse_expiration_time(_), do: DateTime.utc_now()

  defp update_auth(auth, attrs) do
    auth
    |> Auth.changeset(attrs)
    |> Repo.update()
  end

  defp get_auth(nil), do: nil
  defp get_auth(brand_id), do: Repo.get_by(Auth, brand_id: brand_id)

  defp ensure_valid_token(brand_id, auth) do
    # Check if access token is expired or about to expire (within 5 minutes)
    now = DateTime.utc_now()
    expires_soon = DateTime.add(now, 5 * 60, :second)

    if DateTime.compare(auth.access_token_expires_at, expires_soon) == :lt do
      # Token expired or expiring soon, refresh it
      case refresh_access_token(brand_id) do
        {:ok, updated_auth} -> {:ok, updated_auth}
        {:error, reason} -> {:error, {:token_refresh_failed, reason}}
      end
    else
      {:ok, auth}
    end
  end
end
