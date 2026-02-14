defmodule SocialObjects.BigQuery do
  @moduledoc """
  BigQuery REST API client using service account JWT authentication.

  Uses the `req` HTTP library (already available) to make REST API calls.
  Implements JWT-based service account authentication with token caching.
  """

  require Logger

  @oauth_url "https://oauth2.googleapis.com/token"
  @bigquery_scope "https://www.googleapis.com/auth/bigquery"
  @token_cache_key :bigquery_access_token
  @token_ttl_seconds 3500

  @spec query(String.t(), keyword()) :: {:ok, [map()]} | {:error, String.t()}
  @doc """
  Executes a BigQuery SQL query and returns results as a list of maps.

  ## Examples

      iex> SocialObjects.BigQuery.query("SELECT * FROM `dataset.table` LIMIT 10")
      {:ok, [%{"column1" => "value1", ...}, ...]}

      iex> SocialObjects.BigQuery.query("INVALID SQL")
      {:error, "Query failed: ..."}
  """
  def query(sql, opts \\ []) do
    config = build_config(opts)

    with :ok <- validate_config(config),
         {:ok, token} <- get_access_token(config),
         {:ok, response} <- execute_query(sql, token, config.project_id) do
      {:ok, parse_results(response)}
    end
  end

  @spec test_connection(keyword()) :: {:ok, [map()]} | {:error, String.t()}
  @doc """
  Tests the BigQuery connection by running a simple query.
  """
  def test_connection(opts \\ []) do
    query("SELECT 1 as test", opts)
  end

  # Token Management

  defp get_access_token(config) do
    case get_cached_token(config) do
      {:ok, token} ->
        {:ok, token}

      :expired ->
        generate_new_token(config)
    end
  end

  defp get_cached_token(config) do
    case :persistent_term.get(token_cache_key(config), nil) do
      nil ->
        :expired

      {token, expires_at} ->
        if System.system_time(:second) < expires_at do
          {:ok, token}
        else
          :expired
        end
    end
  end

  defp cache_token(config, token, expires_in_seconds) do
    expires_at = System.system_time(:second) + expires_in_seconds
    :persistent_term.put(token_cache_key(config), {token, expires_at})
  end

  defp generate_new_token(config) do
    Logger.debug("[BigQuery] Generating new access token...")

    with {:ok, jwt} <- generate_jwt(config),
         {:ok, response} <- exchange_jwt_for_token(jwt) do
      token = response["access_token"]
      expires_in = response["expires_in"] || 3600
      cache_token(config, token, min(expires_in - 60, @token_ttl_seconds))
      Logger.debug("[BigQuery] Access token generated and cached")
      {:ok, token}
    end
  end

  # JWT Generation

  defp generate_jwt(config) do
    email = config.service_account_email
    private_key_pem = config.private_key

    if is_nil(email) or is_nil(private_key_pem) do
      {:error,
       "BigQuery credentials not configured. Set brand settings or BIGQUERY_SERVICE_ACCOUNT_EMAIL and BIGQUERY_PRIVATE_KEY environment variables."}
    else
      now = System.system_time(:second)

      header = %{
        "alg" => "RS256",
        "typ" => "JWT"
      }

      claims = %{
        "iss" => email,
        "scope" => @bigquery_scope,
        "aud" => @oauth_url,
        "iat" => now,
        "exp" => now + 3600
      }

      case sign_jwt(header, claims, private_key_pem) do
        {:ok, jwt} -> {:ok, jwt}
        {:error, reason} -> {:error, "Failed to sign JWT: #{inspect(reason)}"}
      end
    end
  end

  defp sign_jwt(header, claims, private_key_pem) do
    header_b64 = Base.url_encode64(Jason.encode!(header), padding: false)
    claims_b64 = Base.url_encode64(Jason.encode!(claims), padding: false)
    signing_input = "#{header_b64}.#{claims_b64}"

    # Parse the private key (handle escaped newlines from env vars)
    pem = String.replace(private_key_pem, "\\n", "\n")
    [entry] = :public_key.pem_decode(pem)
    private_key = :public_key.pem_entry_decode(entry)

    signature =
      :public_key.sign(signing_input, :sha256, private_key)
      |> Base.url_encode64(padding: false)

    {:ok, "#{signing_input}.#{signature}"}
  rescue
    e -> {:error, e}
  end

  defp exchange_jwt_for_token(jwt) do
    body =
      URI.encode_query(%{
        "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion" => jwt
      })

    case Req.post(@oauth_url,
           body: body,
           headers: [{"content-type", "application/x-www-form-urlencoded"}]
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, "OAuth token exchange failed (#{status}): #{inspect(body)}"}

      {:error, reason} ->
        {:error, "OAuth request failed: #{inspect(reason)}"}
    end
  end

  # Query Execution

  defp execute_query(sql, token, project_id) do
    url = "https://bigquery.googleapis.com/bigquery/v2/projects/#{project_id}/queries"

    body = %{
      "query" => sql,
      "useLegacySql" => false,
      "maxResults" => 50_000
    }

    Logger.debug("[BigQuery] Executing query: #{String.slice(sql, 0, 100)}...")

    case Req.post(url,
           json: body,
           headers: [{"authorization", "Bearer #{token}"}],
           receive_timeout: 120_000
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        error_message = get_in(body, ["error", "message"]) || inspect(body)
        {:error, "BigQuery query failed (#{status}): #{error_message}"}

      {:error, reason} ->
        {:error, "BigQuery request failed: #{inspect(reason)}"}
    end
  end

  # Result Parsing

  defp parse_results(%{"rows" => rows, "schema" => %{"fields" => fields}}) do
    field_names = Enum.map(fields, & &1["name"])

    Enum.map(rows, fn %{"f" => values} ->
      values
      |> Enum.map(& &1["v"])
      |> Enum.zip(field_names)
      |> Map.new(fn {value, name} -> {name, value} end)
    end)
  end

  defp parse_results(%{"totalRows" => "0"}), do: []
  defp parse_results(%{}), do: []

  # Configuration Helpers

  defp build_config(opts) do
    brand_id = Keyword.get(opts, :brand_id)

    %{
      brand_id: brand_id,
      project_id: SocialObjects.Settings.get_bigquery_project_id(brand_id),
      service_account_email: SocialObjects.Settings.get_bigquery_service_account_email(brand_id),
      private_key: SocialObjects.Settings.get_bigquery_private_key(brand_id)
    }
  end

  defp validate_config(%{project_id: project_id}) when is_binary(project_id) and project_id != "",
    do: :ok

  defp validate_config(_config), do: {:error, :missing_bigquery_project_id}

  defp token_cache_key(%{brand_id: nil}), do: {@token_cache_key, :default}
  defp token_cache_key(%{brand_id: brand_id}), do: {@token_cache_key, brand_id}
end
