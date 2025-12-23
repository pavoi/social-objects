defmodule Mix.Tasks.AuditAffiliateApi do
  @moduledoc """
  Audit new TikTok Shop Affiliate API endpoints to discover available data.

  Tests the following scopes:
  - seller.creator_marketplace.read - Search creators, get performance
  - seller.affiliate_collaboration.write - Manage collaborations

  ## Usage

      # Run full audit
      mix audit_affiliate_api

      # Test only creator marketplace endpoints
      mix audit_affiliate_api --scope marketplace

      # Test only collaboration endpoints
      mix audit_affiliate_api --scope collaboration

      # Verbose mode (show full response bodies)
      mix audit_affiliate_api --verbose
  """

  use Mix.Task
  require Logger

  alias Pavoi.TiktokShop

  @shortdoc "Audit TikTok Shop Affiliate API endpoints"

  # API version for new affiliate endpoints
  @api_version "202509"

  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [scope: :string, verbose: :boolean],
        aliases: [s: :scope, v: :verbose]
      )

    scope = Keyword.get(opts, :scope, "all")
    verbose = Keyword.get(opts, :verbose, false)

    print_header()

    results =
      case scope do
        "marketplace" -> audit_marketplace_endpoints(verbose)
        "collaboration" -> audit_collaboration_endpoints(verbose)
        _ -> audit_marketplace_endpoints(verbose) ++ audit_collaboration_endpoints(verbose)
      end

    print_summary(results)
  end

  defp print_header do
    Mix.shell().info("""

    ╔══════════════════════════════════════════════════════════════════╗
    ║           TikTok Shop Affiliate API Audit                        ║
    ║           Discovering new endpoint capabilities                  ║
    ╚══════════════════════════════════════════════════════════════════╝
    """)
  end

  # ============================================================================
  # Creator Marketplace Endpoints (seller.creator_marketplace.read)
  # ============================================================================

  defp audit_marketplace_endpoints(verbose) do
    Mix.shell().info("""
    ┌──────────────────────────────────────────────────────────────────┐
    │  SCOPE: seller.creator_marketplace.read                         │
    └──────────────────────────────────────────────────────────────────┘
    """)

    endpoints = [
      # Try different path patterns for Search Creator
      {:post, "/affiliate/#{@api_version}/creators/search", %{}, %{},
       "Search Creator on Marketplace (v1)"},
      {:post, "/affiliate/#{@api_version}/seller/creators/search", %{}, %{},
       "Search Creator on Marketplace (v2)"},
      {:post, "/affiliate/#{@api_version}/marketplace/creators/search", %{}, %{},
       "Search Creator on Marketplace (v3)"},
      {:post, "/affiliate/#{@api_version}/creator_marketplace/creators/search", %{}, %{},
       "Search Creator on Marketplace (v4)"},

      # Try with minimal body
      {:post, "/affiliate/#{@api_version}/creators/search", %{},
       %{page_size: 10}, "Search Creator with page_size"},

      # Try GET variant
      {:get, "/affiliate/#{@api_version}/creators", %{page_size: 10}, %{},
       "List Creators (GET variant)"},

      # Creator performance - need a creator_id, try with placeholder
      {:get, "/affiliate/#{@api_version}/creators/performance", %{}, %{},
       "Get Creator Performance (no ID)"},
      {:post, "/affiliate/#{@api_version}/creators/performance", %{}, %{},
       "Get Creator Performance (POST)"}
    ]

    Enum.map(endpoints, fn {method, path, params, body, name} ->
      test_endpoint(method, path, params, body, name, verbose)
    end)
  end

  # ============================================================================
  # Collaboration Management Endpoints (seller.affiliate_collaboration.write)
  # ============================================================================

  defp audit_collaboration_endpoints(verbose) do
    Mix.shell().info("""
    ┌──────────────────────────────────────────────────────────────────┐
    │  SCOPE: seller.affiliate_collaboration.write                    │
    └──────────────────────────────────────────────────────────────────┘
    """)

    # First, try to discover existing collaborations (read operations are safer)
    read_endpoints = [
      # Search/List open collaborations
      {:get, "/affiliate/#{@api_version}/open_collaborations", %{}, %{},
       "List Open Collaborations (GET)"},
      {:post, "/affiliate/#{@api_version}/open_collaborations/search", %{}, %{},
       "Search Open Collaborations"},
      {:get, "/affiliate/#{@api_version}/seller/open_collaborations", %{}, %{},
       "List Seller Open Collaborations"},

      # Search/List target collaborations
      {:get, "/affiliate/#{@api_version}/target_collaborations", %{}, %{},
       "List Target Collaborations (GET)"},
      {:post, "/affiliate/#{@api_version}/target_collaborations/search", %{}, %{},
       "Search Target Collaborations"},
      {:get, "/affiliate/#{@api_version}/seller/target_collaborations", %{}, %{},
       "List Seller Target Collaborations"},

      # Open collaboration settings (read current settings)
      {:get, "/affiliate/#{@api_version}/open_collaborations/settings", %{}, %{},
       "Get Open Collaboration Settings"},
      {:get, "/affiliate/#{@api_version}/seller/open_collaboration_settings", %{}, %{},
       "Get Seller Open Collab Settings"},

      # Sample applications (as seller, view pending applications)
      {:get, "/affiliate/#{@api_version}/sample_applications", %{}, %{},
       "List Sample Applications (GET)"},
      {:post, "/affiliate/#{@api_version}/sample_applications/search", %{}, %{},
       "Search Sample Applications"},
      {:get, "/affiliate/#{@api_version}/seller/sample_applications", %{}, %{},
       "List Seller Sample Applications"},

      # Affiliate orders (seller view)
      {:get, "/affiliate/#{@api_version}/orders", %{}, %{}, "List Affiliate Orders (GET)"},
      {:post, "/affiliate/#{@api_version}/orders/search", %{}, %{}, "Search Affiliate Orders"},
      {:get, "/affiliate/#{@api_version}/seller/affiliate_orders", %{}, %{},
       "List Seller Affiliate Orders"},

      # Try older API version patterns
      {:get, "/affiliate/202309/open_collaborations", %{}, %{},
       "List Open Collaborations (202309)"},
      {:get, "/affiliate/202312/open_collaborations", %{}, %{},
       "List Open Collaborations (202312)"},
      {:get, "/affiliate/202403/open_collaborations", %{}, %{},
       "List Open Collaborations (202403)"}
    ]

    # These are write operations - test with minimal/empty payloads to get schema info
    write_endpoints = [
      # Generate promotion link (relatively safe - just generates a link)
      {:post, "/affiliate/#{@api_version}/products/promotion_link", %{},
       %{product_id: "test"}, "Generate Affiliate Product Link"},
      {:post, "/affiliate/#{@api_version}/promotion_links/generate", %{},
       %{product_id: "test"}, "Generate Promotion Link (alt path)"},

      # Target collaboration link (needs collaboration_id)
      {:post, "/affiliate/#{@api_version}/target_collaborations/link", %{},
       %{}, "Generate Target Collab Link (no ID)"},

      # Get collaboration creation schema by sending empty/minimal body
      {:post, "/affiliate/#{@api_version}/open_collaborations", %{},
       %{}, "Create Open Collaboration (empty - get schema)"},
      {:post, "/affiliate/#{@api_version}/target_collaborations", %{},
       %{}, "Create Target Collaboration (empty - get schema)"}
    ]

    read_results = Enum.map(read_endpoints, fn {method, path, params, body, name} ->
      test_endpoint(method, path, params, body, name, verbose)
    end)

    Mix.shell().info("\n  --- Write Endpoints (probing for schema) ---\n")

    write_results = Enum.map(write_endpoints, fn {method, path, params, body, name} ->
      test_endpoint(method, path, params, body, name, verbose)
    end)

    read_results ++ write_results
  end

  # ============================================================================
  # Endpoint Testing
  # ============================================================================

  defp test_endpoint(method, path, params, body, name, verbose) do
    Mix.shell().info("  Testing: #{name}")
    Mix.shell().info("    #{method |> to_string() |> String.upcase()} #{path}")

    result = TiktokShop.make_api_request(method, path, params, body)

    case result do
      {:ok, response} ->
        handle_success(response, name, verbose)

      {:error, reason} ->
        handle_error(reason, name, verbose)
    end
  end

  defp handle_success(response, name, verbose) do
    # Check if it's a TikTok error response (code != 0)
    case response do
      %{"code" => 0, "data" => data} ->
        Mix.shell().info("    ✅ SUCCESS")
        print_data_summary(data, verbose)
        {:success, name, data}

      %{"code" => code, "message" => message} ->
        Mix.shell().info("    ⚠️  API Error: [#{code}] #{message}")
        if verbose, do: print_full_response(response)
        {:api_error, name, code, message}

      _ ->
        Mix.shell().info("    ✅ Response received")
        if verbose, do: print_full_response(response)
        {:success, name, response}
    end
  end

  defp handle_error(reason, name, verbose) do
    error_str = if is_binary(reason), do: reason, else: inspect(reason)
    Mix.shell().info("    ❌ Error: #{truncate(error_str, 100)}")

    # Extract useful info from error messages
    cond do
      String.contains?(error_str, "Invalid path") ->
        Mix.shell().info("       → Path not found")

      String.contains?(error_str, "scope") or String.contains?(error_str, "permission") ->
        Mix.shell().info("       → Scope/permission issue")

      String.contains?(error_str, "required") ->
        # This is actually useful - tells us what params are needed
        Mix.shell().info("       → Missing required parameters (check full error)")
        if verbose, do: Mix.shell().info("       Full: #{error_str}")

      true ->
        :ok
    end

    if verbose and not String.contains?(error_str, "Invalid path") do
      Mix.shell().info("       Full: #{error_str}")
    end

    Mix.shell().info("")
    {:error, name, reason}
  end

  defp print_data_summary(data, verbose) when is_map(data) do
    keys = Map.keys(data)
    Mix.shell().info("    Data keys: #{Enum.join(keys, ", ")}")

    # Show counts for list fields
    Enum.each(data, fn {key, value} ->
      case value do
        list when is_list(list) ->
          Mix.shell().info("      #{key}: #{length(list)} items")

          if verbose and length(list) > 0 do
            first = List.first(list)

            if is_map(first) do
              Mix.shell().info("        First item keys: #{Map.keys(first) |> Enum.join(", ")}")
            end
          end

        _ ->
          :ok
      end
    end)

    if verbose, do: print_full_response(data)
    Mix.shell().info("")
  end

  defp print_data_summary(data, verbose) do
    if verbose, do: print_full_response(data)
    Mix.shell().info("")
  end

  defp print_full_response(data) do
    json = Jason.encode!(data, pretty: true)
    # Limit output
    lines = String.split(json, "\n")

    if length(lines) > 50 do
      truncated = Enum.take(lines, 50) |> Enum.join("\n")
      Mix.shell().info("\n#{truncated}\n    ... (truncated, #{length(lines)} total lines)")
    else
      Mix.shell().info("\n#{json}")
    end
  end

  # ============================================================================
  # Summary
  # ============================================================================

  defp print_summary(results) do
    successes = Enum.filter(results, fn r -> elem(r, 0) == :success end)
    api_errors = Enum.filter(results, fn r -> elem(r, 0) == :api_error end)
    errors = Enum.filter(results, fn r -> elem(r, 0) == :error end)

    Mix.shell().info("""

    ╔══════════════════════════════════════════════════════════════════╗
    ║                         AUDIT SUMMARY                            ║
    ╚══════════════════════════════════════════════════════════════════╝

    Total endpoints tested: #{length(results)}
    ✅ Successful: #{length(successes)}
    ⚠️  API Errors (valid path, permission/param issue): #{length(api_errors)}
    ❌ Failed (invalid path or network): #{length(errors)}
    """)

    if length(successes) > 0 do
      Mix.shell().info("  Working Endpoints:")

      Enum.each(successes, fn {_, name, _data} ->
        Mix.shell().info("    • #{name}")
      end)
    end

    if length(api_errors) > 0 do
      Mix.shell().info("\n  API Errors (likely valid paths, check permissions/params):")

      Enum.each(api_errors, fn {_, name, code, message} ->
        Mix.shell().info("    • #{name}: [#{code}] #{message}")
      end)
    end

    # Group errors by type
    path_errors = Enum.filter(errors, fn {_, _, reason} ->
      reason_str = if is_binary(reason), do: reason, else: inspect(reason)
      String.contains?(reason_str, "Invalid path") or String.contains?(reason_str, "404")
    end)

    other_errors = errors -- path_errors

    if length(other_errors) > 0 do
      Mix.shell().info("\n  Other Errors (investigate these):")

      Enum.each(other_errors, fn {_, name, reason} ->
        reason_str = if is_binary(reason), do: reason, else: inspect(reason)
        Mix.shell().info("    • #{name}: #{truncate(reason_str, 80)}")
      end)
    end

    Mix.shell().info("""

    ────────────────────────────────────────────────────────────────────
    Next Steps:
    1. For successful endpoints, review the data structure
    2. For API errors, check if you need additional scopes or params
    3. Run with --verbose for full response bodies
    ────────────────────────────────────────────────────────────────────
    """)
  end

  defp truncate(str, max_length) do
    if String.length(str) > max_length do
      String.slice(str, 0, max_length) <> "..."
    else
      str
    end
  end
end
