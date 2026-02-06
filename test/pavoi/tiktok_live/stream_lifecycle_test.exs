defmodule Pavoi.TiktokLive.StreamLifecycleTest do
  @moduledoc """
  Tests for stream lifecycle transitions.

  These tests verify:
  - Stream status transitions are atomic and correct
  - ended_at is set correctly when streams end
  - Duplicate end events are handled correctly
  - report_sent_at marking is atomic
  """

  use Pavoi.DataCase, async: true

  import Pavoi.TiktokLiveFixtures

  alias Pavoi.TiktokLive

  describe "mark_stream_ended/2" do
    test "marks capturing stream as ended with timestamp" do
      brand = brand_fixture()
      stream = stream_fixture(brand: brand, status: :capturing)

      assert is_nil(stream.ended_at)

      {:ok, :ended} = TiktokLive.mark_stream_ended(brand.id, stream.id)

      updated = TiktokLive.get_stream!(brand.id, stream.id)
      assert updated.status == :ended
      assert not is_nil(updated.ended_at)
    end

    test "returns error if stream already ended" do
      brand = brand_fixture()
      stream = stream_fixture(brand: brand, status: :ended)

      {:error, :already_ended} = TiktokLive.mark_stream_ended(brand.id, stream.id)
    end

    test "is idempotent - multiple calls return already_ended" do
      brand = brand_fixture()
      stream = stream_fixture(brand: brand, status: :capturing)

      # First call succeeds
      {:ok, :ended} = TiktokLive.mark_stream_ended(brand.id, stream.id)

      # Subsequent calls return already_ended
      {:error, :already_ended} = TiktokLive.mark_stream_ended(brand.id, stream.id)
      {:error, :already_ended} = TiktokLive.mark_stream_ended(brand.id, stream.id)
    end

    test "does not update ended_at for already ended stream" do
      brand = brand_fixture()

      # Create a stream that ended 1 hour ago
      one_hour_ago = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
      stream = stream_fixture(brand: brand, status: :ended, ended_at: one_hour_ago)

      # Try to end it again
      {:error, :already_ended} = TiktokLive.mark_stream_ended(brand.id, stream.id)

      # ended_at should not have changed
      updated = TiktokLive.get_stream!(brand.id, stream.id)
      assert DateTime.compare(updated.ended_at, one_hour_ago) == :eq
    end
  end

  describe "mark_report_sent/2" do
    test "marks stream report as sent" do
      brand = brand_fixture()
      stream = stream_fixture(brand: brand, status: :ended)

      assert is_nil(stream.report_sent_at)

      {:ok, :marked} = TiktokLive.mark_report_sent(brand.id, stream.id)

      updated = TiktokLive.get_stream!(brand.id, stream.id)
      assert not is_nil(updated.report_sent_at)
    end

    test "returns error if report already sent" do
      brand = brand_fixture()
      stream = stream_fixture(brand: brand, status: :ended)
      stream = mark_report_sent(stream)

      {:error, :already_sent} = TiktokLive.mark_report_sent(brand.id, stream.id)
    end

    test "prevents duplicate report sends atomically" do
      brand = brand_fixture()
      stream = stream_fixture(brand: brand, status: :ended)

      # Simulate concurrent attempts
      results =
        1..5
        |> Task.async_stream(fn _ ->
          TiktokLive.mark_report_sent(brand.id, stream.id)
        end)
        |> Enum.map(fn {:ok, result} -> result end)

      # Exactly one should succeed
      successful = Enum.filter(results, fn r -> r == {:ok, :marked} end)
      failed = Enum.filter(results, fn r -> r == {:error, :already_sent} end)

      assert length(successful) == 1
      assert length(failed) == 4
    end
  end

  describe "stream queries" do
    test "get_stream/2 returns nil for non-existent stream" do
      brand = brand_fixture()

      assert is_nil(TiktokLive.get_stream(brand.id, 999_999))
    end

    test "get_stream!/2 raises for non-existent stream" do
      brand = brand_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        TiktokLive.get_stream!(brand.id, 999_999)
      end
    end

    test "get_active_stream/1 returns capturing stream" do
      brand = brand_fixture()
      stream = stream_fixture(brand: brand, status: :capturing)

      active = TiktokLive.get_active_stream(brand.id)

      assert active.id == stream.id
    end

    test "get_active_stream/1 returns nil when no capturing stream" do
      brand = brand_fixture()
      _stream = stream_fixture(brand: brand, status: :ended)

      assert is_nil(TiktokLive.get_active_stream(brand.id))
    end
  end

  describe "brand isolation" do
    test "streams are isolated by brand" do
      brand1 = brand_fixture(slug: "brand-1")
      brand2 = brand_fixture(slug: "brand-2")

      stream1 = stream_fixture(brand: brand1)
      stream2 = stream_fixture(brand: brand2)

      # Can get own stream
      assert TiktokLive.get_stream(brand1.id, stream1.id).id == stream1.id
      assert TiktokLive.get_stream(brand2.id, stream2.id).id == stream2.id

      # Cannot get other brand's stream
      assert is_nil(TiktokLive.get_stream(brand1.id, stream2.id))
      assert is_nil(TiktokLive.get_stream(brand2.id, stream1.id))
    end

    test "list_streams returns only own brand's streams" do
      brand1 = brand_fixture(slug: "brand-a")
      brand2 = brand_fixture(slug: "brand-b")

      stream1 = stream_fixture(brand: brand1)
      stream2 = stream_fixture(brand: brand2)

      brand1_streams = TiktokLive.list_streams(brand1.id)
      brand2_streams = TiktokLive.list_streams(brand2.id)

      assert Enum.any?(brand1_streams, fn s -> s.id == stream1.id end)
      refute Enum.any?(brand1_streams, fn s -> s.id == stream2.id end)

      assert Enum.any?(brand2_streams, fn s -> s.id == stream2.id end)
      refute Enum.any?(brand2_streams, fn s -> s.id == stream1.id end)
    end
  end
end
