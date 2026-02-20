defmodule SocialObjects.Workers.VideoMetricsDeduperTest do
  use ExUnit.Case, async: true

  alias SocialObjects.Workers.VideoMetricsDeduper

  describe "dedupe_rows/1" do
    test "picks canonical row by highest GMV then views/items" do
      rows = [
        %{
          "id" => "v1",
          "username" => "creator",
          "gmv" => %{"amount" => "73.98"},
          "views" => 2_000,
          "items_sold" => 1,
          "click_through_rate" => "1.0%"
        },
        %{
          "id" => "v1",
          "username" => "creator",
          "gmv" => %{"amount" => "16686.39"},
          "views" => 1_000,
          "items_sold" => 2,
          "click_through_rate" => "2.0%"
        },
        %{
          "id" => "v1",
          "username" => "creator",
          "gmv" => %{"amount" => "16686.39"},
          "views" => 9_000,
          "items_sold" => 2,
          "click_through_rate" => "2.0%"
        }
      ]

      result = VideoMetricsDeduper.dedupe_rows(rows)

      assert length(result.canonical_rows) == 1
      [canonical] = result.canonical_rows

      assert canonical.video_id == "v1"
      assert canonical.metrics.gmv_cents == 1_668_639
      assert canonical.metrics.views == 9_000

      assert result.stats.duplicate_rows == 2
      assert result.stats.duplicate_video_count == 1
      assert result.stats.conflict_video_count == 1
      assert result.stats.max_gmv_discrepancy_cents == 1_661_241
    end
  end

  describe "compare_metric_quality/2" do
    test "returns :gt when left has stronger quality tuple" do
      left = %{gmv_cents: 100_000, views: 10_000, items_sold: 5, gpm_cents: 5_000}
      right = %{gmv_cents: 90_000, views: 100_000, items_sold: 50, gpm_cents: 1_000}

      assert VideoMetricsDeduper.compare_metric_quality(left, right) == :gt
      assert VideoMetricsDeduper.compare_metric_quality(right, left) == :lt
      assert VideoMetricsDeduper.compare_metric_quality(left, left) == :eq
    end
  end
end
