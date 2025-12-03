defmodule Pavoi.Creators do
  @moduledoc """
  The Creators context handles creator/affiliate CRM functionality.

  This context manages creators, their brand relationships, product samples,
  video content, and performance tracking.
  """

  import Ecto.Query, warn: false
  alias Pavoi.Repo

  alias Pavoi.Creators.{
    BrandCreator,
    Creator,
    CreatorPerformanceSnapshot,
    CreatorSample,
    CreatorVideo,
    CreatorVideoProduct
  }

  ## Creators

  @doc """
  Returns the list of creators.
  """
  def list_creators do
    Repo.all(Creator)
  end

  @doc """
  Searches and paginates creators with optional filters.

  ## Options
    - search_query: Search by username, email, first/last name (default: "")
    - brand_id: Filter by brand relationship
    - badge_level: Filter by TikTok badge level
    - page: Current page number (default: 1)
    - per_page: Items per page (default: 50)

  ## Returns
    A map with creators, total, page, per_page, has_more
  """
  def search_creators_paginated(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)
    sort_by = Keyword.get(opts, :sort_by)
    sort_dir = Keyword.get(opts, :sort_dir, "asc")

    query =
      from(c in Creator)
      |> apply_creator_search_filter(Keyword.get(opts, :search_query, ""))
      |> apply_creator_badge_filter(Keyword.get(opts, :badge_level))
      |> apply_creator_brand_filter(Keyword.get(opts, :brand_id))

    total = Repo.aggregate(query, :count)

    creators =
      query
      |> apply_creator_sort(sort_by, sort_dir)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    %{
      creators: creators,
      total: total,
      page: page,
      per_page: per_page,
      has_more: total > page * per_page
    }
  end

  defp apply_creator_sort(query, "username", "asc"),
    do: order_by(query, [c], asc: c.tiktok_username)

  defp apply_creator_sort(query, "username", "desc"),
    do: order_by(query, [c], desc: c.tiktok_username)

  defp apply_creator_sort(query, "followers", "desc"),
    do: order_by(query, [c], desc_nulls_last: c.follower_count)

  defp apply_creator_sort(query, "followers", "asc"),
    do: order_by(query, [c], asc_nulls_last: c.follower_count)

  defp apply_creator_sort(query, "gmv", "desc"),
    do: order_by(query, [c], desc_nulls_last: c.total_gmv_cents)

  defp apply_creator_sort(query, "gmv", "asc"),
    do: order_by(query, [c], asc_nulls_last: c.total_gmv_cents)

  defp apply_creator_sort(query, "videos", "desc"),
    do: order_by(query, [c], desc_nulls_last: c.total_videos)

  defp apply_creator_sort(query, "videos", "asc"),
    do: order_by(query, [c], asc_nulls_last: c.total_videos)

  defp apply_creator_sort(query, "samples", dir) do
    sample_counts =
      from(cs in CreatorSample,
        group_by: cs.creator_id,
        select: %{creator_id: cs.creator_id, count: count(cs.id)}
      )

    query
    |> join(:left, [c], sc in subquery(sample_counts), on: sc.creator_id == c.id)
    |> order_by([c, sc], [{^sort_dir_atom(dir), coalesce(sc.count, 0)}])
  end

  defp apply_creator_sort(query, _, _),
    do: order_by(query, [c], asc: c.tiktok_username)

  defp sort_dir_atom("desc"), do: :desc
  defp sort_dir_atom(_), do: :asc

  defp apply_creator_search_filter(query, ""), do: query

  defp apply_creator_search_filter(query, search_query) do
    # Strip leading @ since usernames are stored without it
    normalized_query = String.trim_leading(search_query, "@")
    pattern = "%#{normalized_query}%"

    where(
      query,
      [c],
      ilike(c.tiktok_username, ^pattern) or
        ilike(c.email, ^pattern) or
        ilike(c.first_name, ^pattern) or
        ilike(c.last_name, ^pattern)
    )
  end

  defp apply_creator_badge_filter(query, nil), do: query

  defp apply_creator_badge_filter(query, badge_level),
    do: where(query, [c], c.tiktok_badge_level == ^badge_level)

  defp apply_creator_brand_filter(query, nil), do: query

  defp apply_creator_brand_filter(query, brand_id) do
    from(c in query,
      join: bc in BrandCreator,
      on: bc.creator_id == c.id,
      where: bc.brand_id == ^brand_id
    )
  end

  @doc """
  Gets a single creator.
  Raises `Ecto.NoResultsError` if the Creator does not exist.
  """
  def get_creator!(id), do: Repo.get!(Creator, id)

  @doc """
  Gets a creator by TikTok username (case-insensitive).
  Returns nil if not found.
  """
  def get_creator_by_username(username) when is_binary(username) do
    normalized = String.downcase(String.trim(username))
    Repo.get_by(Creator, tiktok_username: normalized)
  end

  @doc """
  Gets a creator with all associations preloaded.
  """
  def get_creator_with_details!(id) do
    Creator
    |> where([c], c.id == ^id)
    |> preload([
      :brands,
      creator_samples: [:brand, product: :product_images],
      creator_videos: :video_products,
      performance_snapshots: []
    ])
    |> Repo.one!()
  end

  @doc """
  Creates a creator.
  """
  def create_creator(attrs \\ %{}) do
    %Creator{}
    |> Creator.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a creator.
  """
  def update_creator(%Creator{} = creator, attrs) do
    creator
    |> Creator.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a creator.
  """
  def delete_creator(%Creator{} = creator) do
    Repo.delete(creator)
  end

  @doc """
  Upserts a creator by TikTok username.

  If a creator with the given username exists, merges the new attributes
  (only filling in missing fields, not overwriting existing data).
  If not, creates a new creator.

  Returns `{:ok, creator}` or `{:error, changeset}`.
  """
  def upsert_creator(attrs) do
    username = attrs[:tiktok_username] || attrs["tiktok_username"]

    case get_creator_by_username(username) do
      nil ->
        create_creator(attrs)

      existing ->
        merged = merge_creator_attrs(existing, attrs)
        update_creator(existing, merged)
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp merge_creator_attrs(existing, new) do
    %{
      email: existing.email || get_attr(new, :email),
      phone: existing.phone || normalize_phone(get_attr(new, :phone)),
      phone_verified: merge_phone_verified(existing, new),
      first_name: existing.first_name || get_attr(new, :first_name),
      last_name: existing.last_name || get_attr(new, :last_name),
      address_line_1: existing.address_line_1 || get_attr(new, :address_line_1),
      address_line_2: existing.address_line_2 || get_attr(new, :address_line_2),
      city: existing.city || get_attr(new, :city),
      state: existing.state || get_attr(new, :state),
      zipcode: existing.zipcode || get_attr(new, :zipcode),
      tiktok_profile_url: existing.tiktok_profile_url || get_attr(new, :tiktok_profile_url),
      tiktok_badge_level: get_attr(new, :tiktok_badge_level) || existing.tiktok_badge_level,
      follower_count: get_attr(new, :follower_count) || existing.follower_count,
      total_gmv_cents: get_attr(new, :total_gmv_cents) || existing.total_gmv_cents,
      total_videos: get_attr(new, :total_videos) || existing.total_videos
    }
  end

  # Helper to get attribute from map with atom or string key
  defp get_attr(map, key) when is_atom(key), do: map[key] || map[Atom.to_string(key)]

  defp merge_phone_verified(existing, new) do
    new_phone = get_attr(new, :phone)
    new_verified = get_attr(new, :phone_verified)

    cond do
      new_verified == true -> true
      existing.phone_verified -> true
      new_phone && !phone_masked?(new_phone) -> true
      true -> existing.phone_verified
    end
  end

  defp phone_masked?(nil), do: true
  defp phone_masked?(phone), do: String.contains?(phone, "*")

  @doc """
  Normalizes a phone number to a consistent format.
  Removes non-digit characters except leading +.
  """
  def normalize_phone(nil), do: nil
  def normalize_phone(""), do: nil

  def normalize_phone(phone) when is_binary(phone) do
    # Remove parentheses, spaces, dashes but keep + and digits
    phone
    |> String.replace(~r/[^\d+*]/, "")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  @doc """
  Returns the count of creators.
  """
  def count_creators do
    Repo.aggregate(Creator, :count)
  end

  ## Brand-Creator Relationships

  @doc """
  Lists brands that have at least one creator associated.
  Returns Brand structs.
  """
  def list_brands_with_creators do
    from(b in Pavoi.Catalog.Brand,
      join: bc in BrandCreator,
      on: bc.brand_id == b.id,
      distinct: true,
      order_by: [asc: b.name]
    )
    |> Repo.all()
  end

  @doc """
  Associates a creator with a brand.
  """
  def add_creator_to_brand(creator_id, brand_id, attrs \\ %{}) do
    %BrandCreator{}
    |> BrandCreator.changeset(Map.merge(attrs, %{creator_id: creator_id, brand_id: brand_id}))
    |> Repo.insert(on_conflict: :nothing)
  end

  @doc """
  Gets brands for a creator.
  """
  def list_brands_for_creator(creator_id) do
    from(bc in BrandCreator,
      where: bc.creator_id == ^creator_id,
      join: b in assoc(bc, :brand),
      select: b
    )
    |> Repo.all()
  end

  ## Creator Samples

  @doc """
  Creates a creator sample.
  """
  def create_creator_sample(attrs \\ %{}) do
    %CreatorSample{}
    |> CreatorSample.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists samples for a creator.
  """
  def list_samples_for_creator(creator_id) do
    from(cs in CreatorSample,
      where: cs.creator_id == ^creator_id,
      order_by: [desc: cs.ordered_at],
      preload: [:brand, :product]
    )
    |> Repo.all()
  end

  @doc """
  Gets sample count for a creator.
  """
  def count_samples_for_creator(creator_id) do
    from(cs in CreatorSample, where: cs.creator_id == ^creator_id)
    |> Repo.aggregate(:count)
  end

  ## Creator Videos

  @doc """
  Creates a creator video.
  """
  def create_creator_video(attrs \\ %{}) do
    %CreatorVideo{}
    |> CreatorVideo.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets a video by TikTok video ID.
  """
  def get_video_by_tiktok_id(tiktok_video_id) do
    Repo.get_by(CreatorVideo, tiktok_video_id: tiktok_video_id)
  end

  @doc """
  Lists videos for a creator.
  """
  def list_videos_for_creator(creator_id) do
    from(cv in CreatorVideo,
      where: cv.creator_id == ^creator_id,
      order_by: [desc: cv.posted_at]
    )
    |> Repo.all()
  end

  @doc """
  Gets video count for a creator.
  """
  def count_videos_for_creator(creator_id) do
    from(cv in CreatorVideo, where: cv.creator_id == ^creator_id)
    |> Repo.aggregate(:count)
  end

  ## Video Products

  @doc """
  Links a product to a video.
  """
  def add_product_to_video(video_id, product_id, tiktok_product_id \\ nil) do
    %CreatorVideoProduct{}
    |> CreatorVideoProduct.changeset(%{
      creator_video_id: video_id,
      product_id: product_id,
      tiktok_product_id: tiktok_product_id
    })
    |> Repo.insert(on_conflict: :nothing)
  end

  ## Performance Snapshots

  @doc """
  Creates a performance snapshot.
  """
  def create_performance_snapshot(attrs \\ %{}) do
    %CreatorPerformanceSnapshot{}
    |> CreatorPerformanceSnapshot.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets the latest performance snapshot for a creator.
  """
  def get_latest_snapshot(creator_id) do
    from(s in CreatorPerformanceSnapshot,
      where: s.creator_id == ^creator_id,
      order_by: [desc: s.snapshot_date],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Lists performance snapshots for a creator.
  """
  def list_snapshots_for_creator(creator_id) do
    from(s in CreatorPerformanceSnapshot,
      where: s.creator_id == ^creator_id,
      order_by: [desc: s.snapshot_date]
    )
    |> Repo.all()
  end
end
