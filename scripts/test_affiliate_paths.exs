# Test various affiliate API path patterns
# Run with: mix run scripts/test_affiliate_paths.exs

alias Pavoi.TiktokShop

paths = [
  # Creator marketplace patterns - various structures
  {"/affiliate/202509/seller/marketplace/creators/search", :post},
  {"/affiliate/seller/202509/creators/search", :post},
  {"/seller/202509/affiliate/creators/search", :post},
  {"/creator_marketplace/202509/creators/search", :post},
  {"/seller/202509/creator_marketplace/search", :post},

  # Without nested seller prefix
  {"/affiliate/202509/marketplace/search", :post},
  {"/affiliate/202509/creators", :get},
  {"/affiliate/202509/creators", :post},

  # Maybe "affiliate" without version in first segment
  {"/affiliate/creators/search", :post},
  {"/affiliate/marketplace/creators/search", :post},

  # Different version patterns
  {"/affiliate/202412/creators/search", :post},
  {"/affiliate/202406/creators/search", :post},
  {"/affiliate/202403/creators/search", :post},

  # Open collaboration patterns
  {"/affiliate/202509/seller/open_collaboration", :get},
  {"/affiliate/202509/seller/open_collaboration", :post},
  {"/affiliate/202509/seller/open_collaborations", :get},
  {"/seller/202509/open_collaboration/search", :post},
  {"/affiliate/202509/collaborations/open", :get},
  {"/affiliate/202509/collaboration/open/search", :post},

  # Target collaboration
  {"/affiliate/202509/seller/target_collaboration", :get},
  {"/affiliate/202509/seller/target_collaborations", :get},
  {"/affiliate/202509/target_collaboration/search", :post},

  # Promotion links
  {"/affiliate/202509/promotion/link", :post},
  {"/affiliate/202509/products/promotion/link", :post},
  {"/affiliate/202509/seller/promotion/link", :post},

  # Sample applications
  {"/affiliate/202509/seller/sample_applications", :get},
  {"/affiliate/202509/samples/applications", :get},
  {"/affiliate/202509/sample_application/search", :post},
]

IO.puts("Testing #{length(paths)} path variations...\n")

results = Enum.map(paths, fn {path, method} ->
  result = TiktokShop.make_api_request(method, path, %{page_size: 10}, %{})

  case result do
    {:ok, %{"code" => 0} = response} ->
      IO.puts("✅ SUCCESS: #{method |> to_string() |> String.upcase()} #{path}")
      IO.puts("   Data keys: #{inspect(Map.keys(Map.get(response, "data", %{})))}")
      {:success, path}

    {:ok, %{"code" => code, "message" => msg}} when code != 40006 ->
      IO.puts("⚠️  [#{code}] #{method |> to_string() |> String.upcase()} #{path}")
      IO.puts("   Message: #{msg}")
      {:api_error, path, code, msg}

    {:ok, %{"code" => 40006}} ->
      # Path not found - skip
      {:not_found, path}

    {:error, reason} when is_binary(reason) ->
      if not String.contains?(reason, "40006") do
        IO.puts("❓ #{method |> to_string() |> String.upcase()} #{path}")
        IO.puts("   Error: #{String.slice(reason, 0, 100)}")
        {:error, path, reason}
      else
        {:not_found, path}
      end

    _ ->
      {:unknown, path}
  end
end)

# Summary
successes = Enum.filter(results, fn r -> elem(r, 0) == :success end)
api_errors = Enum.filter(results, fn r -> elem(r, 0) == :api_error end)
not_found = Enum.filter(results, fn r -> elem(r, 0) == :not_found end)

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("SUMMARY")
IO.puts(String.duplicate("=", 60))
IO.puts("✅ Success: #{length(successes)}")
IO.puts("⚠️  API errors (valid path, wrong params/perms): #{length(api_errors)}")
IO.puts("❌ Not found (40006): #{length(not_found)}")

if length(api_errors) > 0 do
  IO.puts("\nAPI Errors (these are valid paths!):")
  Enum.each(api_errors, fn {_, path, code, msg} ->
    IO.puts("  #{path}: [#{code}] #{msg}")
  end)
end
