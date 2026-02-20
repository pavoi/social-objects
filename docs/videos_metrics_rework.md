# /videos Metrics Rework

## Data Model

New table: `creator_video_metric_snapshots`

- Stores period-window snapshots (`window_days` in `[30, 90]`) per video and date
- Unique key: `(brand_id, tiktok_video_id, snapshot_date, window_days)`
- Indexed for latest snapshot lookup by video/window

Primary fields:

- `brand_id`
- `creator_video_id` (nullable, resolved when possible)
- `tiktok_video_id`
- `snapshot_date`
- `window_days`
- `gmv_cents`
- `views`
- `items_sold`
- `gpm_cents`
- `ctr`
- `source_run_id`
- `raw_payload`

## All-Time Strategy (Explicit)

`creator_videos` stores **best-known all-time metrics** (not rolling-window values).

Monotonic fields are guarded during upsert and only move upward:

- `gmv_cents`
- `impressions`
- `items_sold`
- `affiliate_orders`
- `likes`
- `comments`
- `shares`
- `est_commission_cents`

Non-monotonic fields (`gpm_cents`, `ctr`, `duration`, etc.) update only when incoming GMV is at least as strong as the current all-time GMV.

This prevents lower-quality rolling-window rows from regressing all-time values.

## Period Strategy (Explicit)

`/videos` period selection switches metric source:

- `period=all`: all-time values from `creator_videos`
- `period=30`: latest 30-day snapshot values
- `period=90`: latest 90-day snapshot values

The video set is not filtered by `posted_at` when period changes. `posted_at` remains metadata unless explicitly filtered by dedicated posted-date filters.

`min_gmv` and metric sorts (`gmv`, `gpm`, `views`, `ctr`, `items_sold`) apply to the currently selected metric source.

## Duplicate-Row Merge Strategy

Within each sync run/window, duplicate rows for the same `video_id` are merged deterministically:

1. Highest GMV
2. Highest views
3. Highest items sold
4. Most complete metric payload
5. Earliest seen row (stable tie-break)

This canonical row is the only row written for that video/window in that run.

## Backfill Runbook

The backfill task is idempotent and uses the same sync pipeline:

```bash
mix creators.backfill_video_metrics <brand_id>
```

Options:

```bash
mix creators.backfill_video_metrics <brand_id> \
  --snapshot-date YYYY-MM-DD \
  --source-run-id custom-id \
  --with-thumbnails
```

Recommended for production (`brand_id=1`, no thumbnail fetch for speed):

```bash
railway run mix creators.backfill_video_metrics 1 --source-run-id prod-backfill-2026-02-20
```

## Verification SQL

Snapshot coverage by window:

```sql
SELECT window_days, COUNT(*) AS rows
FROM creator_video_metric_snapshots
WHERE brand_id = 1
GROUP BY window_days
ORDER BY window_days;
```

Latest snapshot date by window:

```sql
SELECT window_days, MAX(snapshot_date) AS latest_snapshot_date
FROM creator_video_metric_snapshots
WHERE brand_id = 1
GROUP BY window_days
ORDER BY window_days;
```

Check duplicate key safety (should be zero rows):

```sql
SELECT brand_id, tiktok_video_id, snapshot_date, window_days, COUNT(*) AS dupes
FROM creator_video_metric_snapshots
GROUP BY brand_id, tiktok_video_id, snapshot_date, window_days
HAVING COUNT(*) > 1;
```

Sample regression check for known problematic ID:

```sql
SELECT cv.tiktok_video_id,
       cv.gmv_cents AS all_time_gmv_cents,
       s30.gmv_cents AS latest_30d_gmv_cents,
       s90.gmv_cents AS latest_90d_gmv_cents
FROM creator_videos cv
LEFT JOIN LATERAL (
  SELECT gmv_cents
  FROM creator_video_metric_snapshots s
  WHERE s.brand_id = cv.brand_id
    AND s.tiktok_video_id = cv.tiktok_video_id
    AND s.window_days = 30
  ORDER BY s.snapshot_date DESC, s.id DESC
  LIMIT 1
) s30 ON TRUE
LEFT JOIN LATERAL (
  SELECT gmv_cents
  FROM creator_video_metric_snapshots s
  WHERE s.brand_id = cv.brand_id
    AND s.tiktok_video_id = cv.tiktok_video_id
    AND s.window_days = 90
  ORDER BY s.snapshot_date DESC, s.id DESC
  LIMIT 1
) s90 ON TRUE
WHERE cv.brand_id = 1
  AND cv.tiktok_video_id = '7535909487669005581';
```

## Recovery Limitations

Full historical all-time reconstruction is not possible from rolling-window API responses alone.

Recovered:

- Best-known all-time baseline from existing DB state plus newly fetched canonical rows
- Forward monotonic growth protection (no future regression from low duplicates)
- 30/90 period snapshots from current and future sync runs

Not recovered automatically:

- Exact historical all-time values that were already lost before this fix and are no longer observable via current API windows
