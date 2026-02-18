defmodule SocialObjects.CreatorsThumbnailTest do
  @moduledoc """
  Tests for Creators context thumbnail storage functionality.
  """

  use SocialObjects.DataCase, async: true

  alias SocialObjects.Creators
  alias SocialObjects.Creators.CreatorVideo

  setup do
    brand = brand_fixture()
    creator = creator_fixture(brand.id)

    %{brand: brand, creator: creator}
  end

  describe "search_videos_paginated/1" do
    test "returns thumbnail_storage_key in video results", %{brand: brand, creator: creator} do
      # Create a video with storage key
      video =
        video_fixture(brand.id, creator.id, %{
          thumbnail_url: "https://example.com/thumb.jpg",
          thumbnail_storage_key: "thumbnails/videos/123.jpg"
        })

      result = Creators.search_videos_paginated(brand_id: brand.id)

      assert length(result.videos) == 1
      [returned_video] = result.videos

      assert returned_video.id == video.id
      assert returned_video.thumbnail_storage_key == "thumbnails/videos/123.jpg"
      assert returned_video.thumbnail_url == "https://example.com/thumb.jpg"
    end

    test "returns nil thumbnail_storage_key when not set", %{brand: brand, creator: creator} do
      video =
        video_fixture(brand.id, creator.id, %{
          thumbnail_url: "https://example.com/thumb.jpg",
          thumbnail_storage_key: nil
        })

      result = Creators.search_videos_paginated(brand_id: brand.id)

      [returned_video] = result.videos
      assert returned_video.id == video.id
      assert is_nil(returned_video.thumbnail_storage_key)
      assert returned_video.thumbnail_url == "https://example.com/thumb.jpg"
    end
  end

  describe "update_video_thumbnail/3" do
    test "updates both thumbnail_url and storage_key", %{brand: brand, creator: creator} do
      video =
        video_fixture(brand.id, creator.id, %{
          thumbnail_url: nil,
          thumbnail_storage_key: nil
        })

      {:ok, updated} =
        Creators.update_video_thumbnail(video, "https://new-url.jpg", "thumbnails/videos/new.jpg")

      assert updated.thumbnail_url == "https://new-url.jpg"
      assert updated.thumbnail_storage_key == "thumbnails/videos/new.jpg"
    end

    test "updates thumbnail_url with nil storage_key", %{brand: brand, creator: creator} do
      video =
        video_fixture(brand.id, creator.id, %{
          thumbnail_url: nil,
          thumbnail_storage_key: nil
        })

      {:ok, updated} = Creators.update_video_thumbnail(video, "https://new-url.jpg", nil)

      assert updated.thumbnail_url == "https://new-url.jpg"
      assert is_nil(updated.thumbnail_storage_key)
    end

    test "defaults storage_key to nil when not provided", %{brand: brand, creator: creator} do
      video =
        video_fixture(brand.id, creator.id, %{
          thumbnail_url: nil,
          thumbnail_storage_key: nil
        })

      # Use 2-arity version (backwards compatible)
      {:ok, updated} = Creators.update_video_thumbnail(video, "https://new-url.jpg")

      assert updated.thumbnail_url == "https://new-url.jpg"
      assert is_nil(updated.thumbnail_storage_key)
    end
  end

  describe "list_videos_needing_thumbnail_storage/2" do
    test "returns videos with thumbnail but no storage key", %{brand: brand, creator: creator} do
      # Video needing storage (has thumbnail_url, no storage_key)
      video1 =
        video_fixture(brand.id, creator.id, %{
          thumbnail_url: "https://example.com/thumb1.jpg",
          thumbnail_storage_key: nil,
          video_url: "https://tiktok.com/video/1"
        })

      # Video already in storage (should be excluded)
      _video2 =
        video_fixture(brand.id, creator.id, %{
          thumbnail_url: "https://example.com/thumb2.jpg",
          thumbnail_storage_key: "thumbnails/videos/2.jpg",
          video_url: "https://tiktok.com/video/2"
        })

      # Video without thumbnail (should be excluded)
      _video3 =
        video_fixture(brand.id, creator.id, %{
          thumbnail_url: nil,
          thumbnail_storage_key: nil,
          video_url: "https://tiktok.com/video/3"
        })

      # Video without video_url (should be excluded)
      _video4 =
        video_fixture(brand.id, creator.id, %{
          thumbnail_url: "https://example.com/thumb4.jpg",
          thumbnail_storage_key: nil,
          video_url: nil
        })

      result = Creators.list_videos_needing_thumbnail_storage(brand.id)

      assert length(result) == 1
      assert hd(result).id == video1.id
    end

    test "orders by gmv_cents descending", %{brand: brand, creator: creator} do
      # Lower GMV
      video1 =
        video_fixture(brand.id, creator.id, %{
          thumbnail_url: "https://example.com/thumb1.jpg",
          thumbnail_storage_key: nil,
          video_url: "https://tiktok.com/video/1",
          gmv_cents: 1000
        })

      # Higher GMV
      video2 =
        video_fixture(brand.id, creator.id, %{
          thumbnail_url: "https://example.com/thumb2.jpg",
          thumbnail_storage_key: nil,
          video_url: "https://tiktok.com/video/2",
          gmv_cents: 5000
        })

      result = Creators.list_videos_needing_thumbnail_storage(brand.id)

      assert length(result) == 2
      # Higher GMV should be first
      assert Enum.at(result, 0).id == video2.id
      assert Enum.at(result, 1).id == video1.id
    end

    test "respects limit parameter", %{brand: brand, creator: creator} do
      for i <- 1..5 do
        video_fixture(brand.id, creator.id, %{
          thumbnail_url: "https://example.com/thumb#{i}.jpg",
          thumbnail_storage_key: nil,
          video_url: "https://tiktok.com/video/#{i}",
          gmv_cents: i * 1000
        })
      end

      result = Creators.list_videos_needing_thumbnail_storage(brand.id, 2)

      assert length(result) == 2
    end
  end

  # Helper functions

  defp creator_fixture(brand_id) do
    {:ok, creator} =
      Creators.create_creator(%{
        tiktok_username: "test_creator_#{System.unique_integer([:positive])}"
      })

    _ = Creators.add_creator_to_brand(creator.id, brand_id)
    creator
  end

  defp video_fixture(brand_id, creator_id, attrs) do
    unique_id = System.unique_integer([:positive])

    default_attrs = %{
      tiktok_video_id: "video_#{unique_id}",
      video_url: "https://www.tiktok.com/@testuser/video/#{unique_id}",
      title: "Test Video #{unique_id}",
      gmv_cents: 10_000,
      items_sold: 5
    }

    merged = Map.merge(default_attrs, attrs)

    {:ok, video} =
      %CreatorVideo{brand_id: brand_id, creator_id: creator_id}
      |> CreatorVideo.changeset(merged)
      |> Repo.insert()

    video
  end
end
