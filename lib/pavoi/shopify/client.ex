defmodule Pavoi.Shopify.Client do
  @moduledoc """
  Shopify GraphQL API client for fetching product data.

  Handles authentication, pagination, rate limiting, and response parsing.
  """

  require Logger

  @doc """
  Fetches products from Shopify GraphQL API with pagination support.

  ## Parameters

    - `cursor` - Optional cursor for pagination (default: nil for first page)

  ## Returns

    - `{:ok, %{products: [...], has_next_page: boolean, end_cursor: string | nil}}` on success
    - `{:error, :rate_limited}` when rate limited
    - `{:error, reason}` on other errors

  ## Examples

      iex> Pavoi.Shopify.Client.fetch_products()
      {:ok, %{products: [...], has_next_page: true, end_cursor: "..."}}

      iex> Pavoi.Shopify.Client.fetch_products("cursor_string")
      {:ok, %{products: [...], has_next_page: false, end_cursor: nil}}
  """
  def fetch_products(cursor \\ nil) do
    query = build_products_query()
    variables = %{cursor: cursor}

    case execute_graphql(query, variables) do
      {:ok, response} -> parse_products_response(response)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fetches all products by paginating through the entire catalog.

  Returns all products as a flat list.

  ## Returns

    - `{:ok, [products]}` on success
    - `{:error, reason}` on error
  """
  def fetch_all_products do
    fetch_all_products_recursive(nil, [])
  end

  defp fetch_all_products_recursive(cursor, accumulated_batches) do
    case fetch_products(cursor) do
      {:ok, %{products: products, has_next_page: false}} ->
        # Reverse and flatten accumulated batches for correct order
        all_products = Enum.reverse([products | accumulated_batches]) |> List.flatten()
        {:ok, all_products}

      {:ok, %{products: products, has_next_page: true, end_cursor: next_cursor}} ->
        Logger.info("Fetched #{length(products)} products, continuing with cursor...")
        # Prepend batch (O(1)) instead of append (O(n))
        fetch_all_products_recursive(next_cursor, [products | accumulated_batches])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_graphql(query, variables) do
    url = graphql_url()
    headers = build_headers()
    body = Jason.encode!(%{query: query, variables: variables})

    case Req.post(url, headers: headers, body: body) do
      {:ok, %{status: 200, body: body}} ->
        case body do
          %{"data" => data} -> {:ok, data}
          %{"errors" => errors} -> {:error, {:graphql_errors, errors}}
        end

      {:ok, %{status: 429}} ->
        Logger.warning("Shopify API rate limit hit")
        {:error, :rate_limited}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Shopify API error: status=#{status}, body=#{inspect(body)}")
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        Logger.error("HTTP request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  defp parse_products_response(%{"products" => products_data}) do
    products = products_data["nodes"] || []
    page_info = products_data["pageInfo"] || %{}

    {:ok,
     %{
       products: products,
       has_next_page: page_info["hasNextPage"] || false,
       end_cursor: page_info["endCursor"]
     }}
  end

  defp build_products_query do
    """
    query($cursor: String) {
      products(first: 250, after: $cursor) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          id
          title
          handle
          descriptionHtml
          vendor
          tags
          createdAt
          updatedAt
          variants(first: 100) {
            nodes {
              id
              title
              price
              compareAtPrice
              sku
              selectedOptions {
                name
                value
              }
            }
          }
          images(first: 10) {
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

  defp build_headers do
    token = Application.fetch_env!(:pavoi, :shopify_access_token)

    [
      {"Content-Type", "application/json"},
      {"X-Shopify-Access-Token", token}
    ]
  end

  defp graphql_url do
    store_name = Application.fetch_env!(:pavoi, :shopify_store_name)
    "https://#{store_name}.myshopify.com/admin/api/2024-10/graphql.json"
  end
end
