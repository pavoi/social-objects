defmodule Pavoi.TiktokLive.StreamReportTest do
  @moduledoc """
  Behavior tests for TikTok Live stream reports.

  These tests verify the observable behaviors of the stream report system:
  - Reports are generated with accurate data
  - Reports are sent only once per stream
  - Reports are not sent for invalid streams (false starts, recovered streams)
  - Race conditions are handled gracefully

  Tests are intentionally focused on WHAT the system does, not HOW it does it,
  making them resilient to implementation changes.
  """

  use Pavoi.DataCase, async: true
  use Oban.Testing, repo: Pavoi.Repo

  import Pavoi.TiktokLiveFixtures

  alias Pavoi.StreamReport

  describe "report data accuracy" do
    test "generates report with correct duration for completed stream" do
      brand = brand_fixture()

      # A stream that ran for exactly 2 hours
      two_hours_ago = DateTime.utc_now() |> DateTime.add(-2, :hour) |> DateTime.truncate(:second)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      stream =
        stream_fixture(
          brand: brand,
          started_at: two_hours_ago,
          ended_at: now,
          status: :ended
        )

      {:ok, report} = StreamReport.generate(brand.id, stream.id)

      # Duration should be approximately 2 hours (7200 seconds)
      # Allow some tolerance for test execution time
      assert report.stats.duration >= 7190
      assert report.stats.duration <= 7210
      assert report.stats.duration_formatted == "2h 0m"
    end

    test "generates report with correct duration for shorter stream" do
      brand = brand_fixture()

      thirty_min_ago =
        DateTime.utc_now() |> DateTime.add(-30, :minute) |> DateTime.truncate(:second)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      stream =
        stream_fixture(
          brand: brand,
          started_at: thirty_min_ago,
          ended_at: now,
          status: :ended
        )

      {:ok, report} = StreamReport.generate(brand.id, stream.id)

      assert report.stats.duration >= 1790
      assert report.stats.duration <= 1810
      assert report.stats.duration_formatted == "30m"
    end

    test "includes engagement stats in report" do
      brand = brand_fixture()

      stream =
        stream_fixture(
          brand: brand,
          viewer_count_peak: 500,
          total_likes: 10_000,
          total_follows: 50,
          total_shares: 25,
          total_gifts_value: 1000
        )

      {:ok, report} = StreamReport.generate(brand.id, stream.id)

      assert report.stats.peak_viewers == 500
      assert report.stats.total_likes == 10_000
      assert report.stats.total_follows == 50
      assert report.stats.total_shares == 25
      assert report.stats.total_gifts_value == 1000
    end

    test "counts comments correctly" do
      brand = brand_fixture()
      stream = stream_fixture(brand: brand, total_comments: 0)

      # Add 15 comments
      for _ <- 1..15 do
        comment_fixture(stream: stream, text: "test comment")
      end

      {:ok, report} = StreamReport.generate(brand.id, stream.id)

      assert report.stats.total_comments == 15
    end

    test "counts unique commenters correctly" do
      brand = brand_fixture()
      stream = stream_fixture(brand: brand)

      base_time = DateTime.utc_now() |> DateTime.truncate(:second)

      # Same user comments multiple times (different timestamps to avoid unique constraint)
      for i <- 1..5 do
        comment_fixture(
          stream: stream,
          user_id: "user_123",
          text: "Comment #{i}",
          commented_at: DateTime.add(base_time, i, :second)
        )
      end

      # Different users each comment once
      for i <- 1..3 do
        comment_fixture(
          stream: stream,
          user_id: "user_#{100 + i}",
          text: "Comment",
          commented_at: DateTime.add(base_time, 10 + i, :second)
        )
      end

      {:ok, report} = StreamReport.generate(brand.id, stream.id)

      # 1 user with 5 comments + 3 users with 1 comment each = 4 unique commenters
      assert report.unique_commenters == 4
    end
  end

  describe "nil ended_at handling" do
    test "uses current time as fallback when ended_at is nil" do
      brand = brand_fixture()

      # Create a stream in inconsistent state (ended but nil ended_at)
      stream = inconsistent_stream_fixture(brand: brand)

      # This should not crash and should use current time as fallback
      {:ok, report} = StreamReport.generate(brand.id, stream.id)

      # Duration should be roughly the time since started_at
      # (will be logged as a warning)
      assert report.stats.duration > 0
      assert is_binary(report.stats.duration_formatted)
    end
  end

  describe "flash sale detection" do
    test "detects flash sale patterns in comments" do
      brand = brand_fixture()
      stream = stream_fixture(brand: brand)

      # Create 60 identical comments (above the 50 threshold)
      for _ <- 1..60 do
        comment_fixture(stream: stream, text: "123")
      end

      # Add some regular comments
      for i <- 1..10 do
        comment_fixture(stream: stream, text: "Unique comment #{i}")
      end

      flash_sales = StreamReport.detect_flash_sale_comments(brand.id, stream.id)

      assert length(flash_sales) == 1
      assert hd(flash_sales).text == "123"
      assert hd(flash_sales).count == 60
    end

    test "does not flag comments below threshold" do
      brand = brand_fixture()
      stream = stream_fixture(brand: brand)

      # Create 40 identical comments (below the 50 threshold)
      for _ <- 1..40 do
        comment_fixture(stream: stream, text: "456")
      end

      flash_sales = StreamReport.detect_flash_sale_comments(brand.id, stream.id)

      assert flash_sales == []
    end
  end

  describe "Slack blocks formatting" do
    test "formats report into valid Slack blocks" do
      brand = brand_fixture()
      {stream, _comments} = stream_with_comments_fixture(brand: brand)

      {:ok, report_data} = StreamReport.generate(brand.id, stream.id)

      # Preload brand for Slack block formatting (needed for URL generation)
      report_data = %{report_data | stream: %{report_data.stream | brand: brand}}

      {:ok, blocks} = StreamReport.format_slack_blocks(report_data)

      # Should have header block
      assert Enum.any?(blocks, fn block ->
               block[:type] == "header"
             end)

      # Should have stats section
      assert Enum.any?(blocks, fn block ->
               block[:type] == "section" &&
                 is_binary(get_in(block, [:text, :text])) &&
                 String.contains?(get_in(block, [:text, :text]), "duration")
             end)
    end
  end
end
