defmodule Pavoi.Shopify.ApiTest do
  @moduledoc """
  Quick test module to verify Shopify GraphQL API connectivity and explore available data.

  Usage in iex:
    iex -S mix
    Pavoi.Shopify.ApiTest.test_connectivity()
    Pavoi.Shopify.ApiTest.fetch_sample_products()
  """

  def test_connectivity do
    IO.puts("Testing Shopify API connectivity...")

    case make_request(simple_query()) do
      {:ok, response} ->
        IO.puts("\n✅ Connected! Response:")
        IO.puts(inspect(response, pretty: true, limit: :infinity))
        {:ok, response}

      {:error, reason} ->
        IO.puts("\n❌ Error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def fetch_sample_products do
    IO.puts("Fetching sample products from Shopify...")

    case make_request(products_query()) do
      {:ok, %{"data" => %{"products" => %{"nodes" => products}}}} ->
        IO.puts("\n✅ Found #{length(products)} products. First product:")
        IO.puts(inspect(List.first(products), pretty: true, limit: :infinity))
        {:ok, products}

      {:ok, response} ->
        IO.puts("\n⚠️  Got response but unexpected structure:")
        IO.puts(inspect(response, pretty: true, limit: :infinity))
        {:ok, response}

      {:error, reason} ->
        IO.puts("\n❌ Error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def check_rate_limits do
    IO.puts("Checking rate limit status...")

    case make_request(rate_limit_query()) do
      {:ok, %{"extensions" => %{"cost" => cost_info}}} ->
        IO.puts("\n✅ Rate limit info:")
        IO.puts(inspect(cost_info, pretty: true))
        {:ok, cost_info}

      {:ok, response} ->
        IO.puts("\n⚠️  Got response but no cost info:")
        IO.puts(inspect(response, pretty: true, limit: :infinity))
        {:ok, response}

      {:error, reason} ->
        IO.puts("\n❌ Error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ============================================================================
  # GraphQL Queries
  # ============================================================================

  defp simple_query do
    """
    {
      shop {
        name
        primaryDomain {
          url
        }
      }
    }
    """
  end

  defp products_query do
    """
    {
      products(first: 5) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          id
          title
          handle
          vendor
          productType
          tags
          descriptionHtml
          createdAt
          updatedAt
          variants(first: 3) {
            nodes {
              id
              title
              price
              compareAtPrice
              sku
              barcode
              inventoryQuantity
              selectedOptions {
                name
                value
              }
            }
          }
          images(first: 3) {
            nodes {
              id
              url
              altText
              height
              width
            }
          }
        }
      }
    }
    """
  end

  defp rate_limit_query do
    """
    {
      products(first: 1) {
        nodes {
          id
          title
        }
      }
    }
    """
  end

  # ============================================================================
  # HTTP Request Handling
  # ============================================================================

  defp make_request(query) do
    with {:ok, token} <- get_access_token(),
         {:ok, store} <- get_store_name() do
      send_graphql_request(store, token, query)
    end
  end

  defp get_access_token do
    case Application.get_env(:pavoi, :shopify_access_token) do
      nil ->
        {:error,
         "SHOPIFY_ACCESS_TOKEN not configured in .env. Please add your token and restart iex."}

      "your_access_token_here" ->
        {:error,
         "SHOPIFY_ACCESS_TOKEN not configured in .env. Please add your token and restart iex."}

      token ->
        {:ok, token}
    end
  end

  defp get_store_name do
    case Application.get_env(:pavoi, :shopify_store_name) do
      nil ->
        {:error,
         "SHOPIFY_STORE_NAME not configured in .env. Please add your store name and restart iex."}

      "your-store-name" ->
        {:error,
         "SHOPIFY_STORE_NAME not configured in .env. Please add your store name and restart iex."}

      store ->
        {:ok, store}
    end
  end

  defp send_graphql_request(store, token, query) do
    endpoint = "https://#{store}.myshopify.com/admin/api/2025-10/graphql.json"

    headers = [
      {"X-Shopify-Access-Token", token},
      {"Content-Type", "application/json"}
    ]

    body = Jason.encode!(%{query: query})

    case HTTPoison.post(endpoint, body, headers) do
      {:ok, %{status_code: 200, body: response_body}} ->
        Jason.decode(response_body)

      {:ok, %{status_code: 429}} ->
        {:error, "Rate limited (429). Wait before retrying."}

      {:ok, %{status_code: 401}} ->
        {:error, "Unauthorized (401). Check SHOPIFY_ACCESS_TOKEN."}

      {:ok, %{status_code: 403}} ->
        {:error, "Forbidden (403). Check scopes - need 'read_products' at minimum."}

      {:ok, %{status_code: code, body: response_body}} ->
        {:error, "HTTP #{code}: #{response_body}"}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
