# Backfill GMV data for existing ended streams
#
# Run with:
#   mix run priv/repo/scripts/backfill_stream_gmv.exs
#
# Or in production:
#   DATABASE_URL=... MIX_ENV=prod mix run priv/repo/scripts/backfill_stream_gmv.exs

alias Pavoi.Repo
alias Pavoi.TiktokLive.Stream
alias Pavoi.TiktokShop
import Ecto.Query

IO.puts("Fetching ended streams without hourly GMV data...")

streams =
  from(s in Stream,
    where: s.status == :ended,
    where: is_nil(s.gmv_hourly),
    where: not is_nil(s.started_at),
    where: not is_nil(s.ended_at),
    order_by: [desc: s.started_at]
  )
  |> Repo.all()

IO.puts("Found #{length(streams)} streams to backfill")

Enum.each(streams, fn stream ->
  IO.write("Processing stream ##{stream.id} (#{stream.unique_id})... ")

  case TiktokShop.fetch_orders_in_range(stream.started_at, stream.ended_at) do
    {:ok, orders} ->
      hourly = TiktokShop.calculate_hourly_gmv(orders)
      total_cents = Enum.reduce(hourly, 0, fn h, acc -> acc + h.gmv_cents end)
      order_count = Enum.reduce(hourly, 0, fn h, acc -> acc + h.order_count end)

      # Serialize hourly data for storage
      hourly_map = %{
        "data" =>
          Enum.map(hourly, fn h ->
            %{
              "hour" => DateTime.to_iso8601(h.hour),
              "gmv_cents" => h.gmv_cents,
              "order_count" => h.order_count
            }
          end)
      }

      stream
      |> Stream.changeset(%{
        gmv_cents: total_cents,
        gmv_order_count: order_count,
        gmv_hourly: hourly_map
      })
      |> Repo.update!()

      IO.puts("GMV: $#{total_cents / 100} (#{order_count} orders, #{length(hourly)} hours)")

    {:error, reason} ->
      IO.puts("Error: #{inspect(reason)}")
  end

  # Rate limit to avoid hitting TikTok API too hard
  Process.sleep(500)
end)

IO.puts("\nBackfill complete!")
