import Ecto.Query
alias SocialObjects.Repo
alias SocialObjects.Settings.SystemSetting

brand_id = 1

IO.puts("=== Backfilling status_key values for brand #{brand_id} ===\n")

# Helper to upsert a setting
upsert = fn key, value ->
  case Repo.get_by(SystemSetting, brand_id: brand_id, key: key) do
    nil ->
      %SystemSetting{}
      |> SystemSetting.changeset(%{brand_id: brand_id, key: key, value: value, value_type: "datetime"})
      |> Repo.insert!()
      IO.puts("Created #{key}: #{value}")
    existing ->
      existing
      |> SystemSetting.changeset(%{value: value})
      |> Repo.update!()
      IO.puts("Updated #{key}: #{value}")
  end
end

# 1. stream_capture_last_run_at - most recent ended stream
stream = Repo.one(from s in "tiktok_streams",
  where: s.brand_id == ^brand_id and s.status == "ended" and not is_nil(s.ended_at),
  order_by: [desc: s.ended_at],
  limit: 1,
  select: %{ended_at: s.ended_at})

if stream do
  dt = DateTime.from_naive!(stream.ended_at, "Etc/UTC")
  upsert.("stream_capture_last_run_at", DateTime.to_iso8601(dt))
else
  IO.puts("No ended streams found for stream_capture_last_run_at")
end

# 2. stream_report_last_sent_at - most recent stream with report_sent_at
stream_report = Repo.one(from s in "tiktok_streams",
  where: s.brand_id == ^brand_id and not is_nil(s.report_sent_at),
  order_by: [desc: s.report_sent_at],
  limit: 1,
  select: %{report_sent_at: s.report_sent_at})

if stream_report do
  dt = DateTime.from_naive!(stream_report.report_sent_at, "Etc/UTC")
  upsert.("stream_report_last_sent_at", DateTime.to_iso8601(dt))
else
  IO.puts("No streams with report_sent_at found")
end

# 3. talking_points_last_run_at - most recent completed generation
generation = Repo.one(from g in "talking_points_generations",
  where: g.brand_id == ^brand_id and g.status == "completed",
  order_by: [desc: g.updated_at],
  limit: 1,
  select: %{updated_at: g.updated_at})

if generation do
  # Convert NaiveDateTime to DateTime
  dt = DateTime.from_naive!(generation.updated_at, "Etc/UTC")
  upsert.("talking_points_last_run_at", DateTime.to_iso8601(dt))
else
  IO.puts("No completed generations found for talking_points_last_run_at")
end

# 4. gmv_backfill_last_run_at - most recent stream with GMV data
gmv_stream = Repo.one(from s in "tiktok_streams",
  where: s.brand_id == ^brand_id and not is_nil(s.gmv_cents),
  order_by: [desc: s.updated_at],
  limit: 1,
  select: %{updated_at: s.updated_at})

if gmv_stream do
  dt = DateTime.from_naive!(gmv_stream.updated_at, "Etc/UTC")
  upsert.("gmv_backfill_last_run_at", DateTime.to_iso8601(dt))
else
  IO.puts("No streams with GMV data found for gmv_backfill_last_run_at")
end

# 5. token_refresh_last_run_at - already set, skip
existing = Repo.get_by(SystemSetting, brand_id: brand_id, key: "token_refresh_last_run_at")
if existing do
  IO.puts("token_refresh_last_run_at already set: #{existing.value}")
else
  IO.puts("token_refresh_last_run_at not set (will be set on next refresh)")
end

IO.puts("\n=== Backfill complete ===")
