defmodule SocialObjects.Workers.VideoMetricsDeduper do
  @moduledoc """
  Canonical dedupe/merge utilities for TikTok video performance rows.

  TikTok can return duplicate `video_id` rows across pages with conflicting values.
  This module deterministically picks one canonical row per video by preferring:

  1. Highest GMV
  2. Highest views
  3. Highest items sold
  4. Most complete metric payload
  5. Earliest page/order appearance (stable tie-break)
  """

  alias SocialObjects.TiktokShop.Parsers

  @type metric_map :: %{
          optional(:gmv_cents) => integer() | nil,
          optional(:views) => integer() | nil,
          optional(:impressions) => integer() | nil,
          optional(:items_sold) => integer() | nil,
          optional(:gpm_cents) => integer() | nil,
          optional(:ctr) => Decimal.t() | nil
        }

  @type canonical_row :: %{
          video_id: String.t() | nil,
          username: String.t() | nil,
          raw: map(),
          metrics: metric_map(),
          first_seen: non_neg_integer(),
          score: tuple()
        }

  @spec dedupe_rows([map()]) :: %{canonical_rows: [canonical_row()], stats: map()}
  def dedupe_rows(rows) when is_list(rows) do
    candidates =
      rows
      |> Enum.with_index()
      |> Enum.map(fn {row, index} -> build_candidate(row, index) end)

    grouped = Enum.group_by(candidates, &dedupe_key/1)

    canonical_rows =
      grouped
      |> Enum.map(fn {_key, group} -> pick_best_candidate(group) end)
      |> Enum.sort_by(& &1.first_seen, :asc)

    duplicate_rows =
      grouped
      |> Enum.reduce(0, fn {_key, group}, acc ->
        acc + max(length(group) - 1, 0)
      end)

    {conflict_video_count, max_gmv_discrepancy_cents} = conflict_stats(grouped)

    %{
      canonical_rows: canonical_rows,
      stats: %{
        total_rows: length(rows),
        canonical_rows: length(canonical_rows),
        duplicate_rows: duplicate_rows,
        duplicate_video_count: Enum.count(grouped, fn {_k, group} -> length(group) > 1 end),
        conflict_video_count: conflict_video_count,
        max_gmv_discrepancy_cents: max_gmv_discrepancy_cents
      }
    }
  end

  @doc """
  Compares two metric maps with the same quality ordering used by dedupe.

  Returns `:gt` if left is better, `:lt` if right is better, and `:eq` otherwise.
  """
  @spec compare_metric_quality(metric_map(), metric_map()) :: :gt | :lt | :eq
  def compare_metric_quality(left, right) when is_map(left) and is_map(right) do
    left_score = metric_quality_tuple(left)
    right_score = metric_quality_tuple(right)

    cond do
      left_score > right_score -> :gt
      left_score < right_score -> :lt
      true -> :eq
    end
  end

  defp dedupe_key(%{video_id: nil, first_seen: index}), do: "__missing_video_id__#{index}"
  defp dedupe_key(%{video_id: "", first_seen: index}), do: "__blank_video_id__#{index}"
  defp dedupe_key(%{video_id: video_id}), do: video_id

  defp pick_best_candidate([candidate]), do: candidate

  defp pick_best_candidate(candidates) do
    Enum.max_by(candidates, & &1.score)
  end

  defp build_candidate(row, index) do
    metrics = parse_metrics(row)

    %{
      video_id: row["id"],
      username: row["username"],
      raw: row,
      metrics: metrics,
      first_seen: index,
      score: metric_quality_tuple(metrics, index)
    }
  end

  defp parse_metrics(row) do
    %{
      gmv_cents: Parsers.parse_gmv_cents(row["gmv"], default: 0),
      gpm_cents: Parsers.parse_gmv_cents(row["gpm"]),
      views: Parsers.parse_integer(row["views"], default: 0),
      items_sold: Parsers.parse_integer(row["items_sold"], default: 0),
      ctr: Parsers.parse_percentage(row["click_through_rate"]),
      duration: Parsers.parse_integer(row["duration"]),
      posted_at: Parsers.parse_video_post_time(row["video_post_time"]),
      hash_tags: Parsers.parse_hash_tags(row["hash_tags"])
    }
  end

  defp conflict_stats(grouped) do
    grouped
    |> Enum.reduce({0, 0}, fn {_key, group}, {count_acc, max_acc} ->
      merge_conflict_stats({count_acc, max_acc}, conflict_stats_for_group(group))
    end)
  end

  defp merge_conflict_stats({count_acc, max_acc}, {count_delta, max_delta}) do
    {count_acc + count_delta, max(max_acc, max_delta)}
  end

  defp conflict_stats_for_group(group) when length(group) <= 1, do: {0, 0}

  defp conflict_stats_for_group(group) do
    gmv_values = Enum.map(group, fn candidate -> candidate.metrics.gmv_cents || 0 end)
    views_values = Enum.map(group, fn candidate -> candidate.metrics.views || 0 end)
    items_values = Enum.map(group, fn candidate -> candidate.metrics.items_sold || 0 end)

    gmv_discrepancy = Enum.max(gmv_values) - Enum.min(gmv_values)
    conflict? = conflict_detected?(gmv_discrepancy, views_values, items_values)

    if conflict? do
      {1, gmv_discrepancy}
    else
      {0, 0}
    end
  end

  defp conflict_detected?(gmv_discrepancy, views_values, items_values) do
    gmv_discrepancy > 0 or
      Enum.max(views_values) != Enum.min(views_values) or
      Enum.max(items_values) != Enum.min(items_values)
  end

  defp metric_quality_tuple(metrics, first_seen_index \\ 0) do
    views = Map.get(metrics, :views) || Map.get(metrics, :impressions) || 0

    {
      Map.get(metrics, :gmv_cents) || 0,
      views,
      Map.get(metrics, :items_sold) || 0,
      metric_completeness(metrics),
      -first_seen_index
    }
  end

  defp metric_completeness(metrics) do
    metrics
    |> Map.values()
    |> Enum.reject(&is_nil/1)
    |> length()
  end
end
