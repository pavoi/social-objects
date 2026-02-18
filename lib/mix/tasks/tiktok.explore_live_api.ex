defmodule Mix.Tasks.Tiktok.ExploreLiveApi do
  @moduledoc """
  Explore TikTok Shop Live Analytics API to discover available fields.

  Usage:
    mix tiktok.explore_live_api [brand_id] [--days N]

  If brand_id is not provided, uses the first brand with TikTok Shop auth.
  Default date range is last 30 days.
  """

  use Mix.Task

  alias SocialObjects.Repo
  alias SocialObjects.TiktokShop.Analytics
  alias SocialObjects.TiktokShop.Auth

  import Ecto.Query

  @shortdoc "Explore TikTok Shop Live Analytics API fields"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, args, _} = OptionParser.parse(args, switches: [days: :integer])
    days = Keyword.get(opts, :days, 30)
    brand_id = parse_brand_id(args)

    validate_brand_id!(brand_id)

    Mix.shell().info("Using brand_id: #{brand_id}")
    Mix.shell().info("Fetching live sessions from last #{days} days...\n")

    fetch_and_display_sessions(brand_id, days)
  end

  defp parse_brand_id([id | _]), do: String.to_integer(id)
  defp parse_brand_id([]), do: get_first_brand_with_auth()

  defp validate_brand_id!(nil) do
    Mix.shell().error("No brand with TikTok Shop auth found")
    exit(:shutdown)
  end

  defp validate_brand_id!(_brand_id), do: :ok

  defp fetch_and_display_sessions(brand_id, days) do
    end_date = Date.utc_today() |> Date.add(1) |> Date.to_iso8601()
    start_date = Date.utc_today() |> Date.add(-days) |> Date.to_iso8601()

    result =
      Analytics.get_shop_live_performance_list(brand_id,
        start_date_ge: start_date,
        end_date_lt: end_date,
        page_size: 5,
        account_type: "ALL"
      )

    handle_api_response(result)
  end

  defp handle_api_response({:ok, %{"data" => data}}) when is_map(data) do
    sessions = Map.get(data, "live_stream_sessions", [])
    Mix.shell().info("Found #{length(sessions)} sessions\n")
    display_sessions(sessions)
  end

  defp handle_api_response({:ok, %{"data" => nil}}) do
    Mix.shell().info("API returned no data (data: null)")
  end

  defp handle_api_response({:ok, response}) do
    Mix.shell().error("Unexpected response structure:")
    Mix.shell().info(inspect(response, pretty: true, limit: :infinity))
  end

  defp handle_api_response({:error, reason}) do
    Mix.shell().error("API error: #{inspect(reason)}")
  end

  defp display_sessions([]) do
    Mix.shell().info("No sessions found. Try a larger date range with --days N")
  end

  defp display_sessions([first_session | _]) do
    Mix.shell().info("=== FULL SESSION STRUCTURE ===\n")
    Mix.shell().info(inspect(first_session, pretty: true, limit: :infinity))

    interaction = first_session["interaction_performance"] || %{}
    sales = first_session["sales_performance"] || %{}
    top_level = Map.drop(first_session, ["interaction_performance", "sales_performance"])

    Mix.shell().info("\n\n=== INTERACTION_PERFORMANCE FIELDS ===\n")
    print_fields("interaction_performance", interaction)

    Mix.shell().info("\n=== SALES_PERFORMANCE FIELDS ===\n")
    print_fields("sales_performance", sales)

    Mix.shell().info("\n=== TOP-LEVEL SESSION FIELDS ===\n")
    print_fields("session", top_level)

    print_field_summary(interaction)
  end

  defp print_field_summary(interaction) do
    Mix.shell().info("\n=== SUMMARY: Fields in interaction_performance ===")

    interaction
    |> Map.keys()
    |> Enum.sort()
    |> Enum.each(fn key -> Mix.shell().info("  - #{key}") end)
  end

  defp get_first_brand_with_auth do
    from(a in Auth,
      where: not is_nil(a.access_token),
      select: a.brand_id,
      limit: 1
    )
    |> Repo.one()
  end

  defp print_fields(prefix, map) when is_map(map) do
    map
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.each(fn {key, value} ->
      Mix.shell().info("  #{prefix}.#{key}: #{inspect(value)}")
    end)
  end
end
