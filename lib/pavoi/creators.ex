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
    CreatorPurchase,
    CreatorSample,
    CreatorTag,
    CreatorTagAssignment,
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
      |> apply_creator_tag_filter(Keyword.get(opts, :tag_ids))

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

  @doc """
  Unified search for creators with all filters from both CRM and Outreach modes.

  ## Options
    - search_query: Search by username, email, first/last name
    - badge_level: Filter by TikTok badge level
    - tag_ids: Filter by tag IDs
    - outreach_status: Filter by outreach status (nil = all, or "pending"/"sent"/"skipped")
    - sort_by: Column to sort (supports all CRM and outreach columns)
    - sort_dir: "asc" or "desc"
    - page: Page number (default: 1)
    - per_page: Items per page (default: 50)

  ## Returns
    A map with creators, total, page, per_page, has_more
  """
  def search_creators_unified(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)
    sort_by = Keyword.get(opts, :sort_by, "gmv")
    sort_dir = Keyword.get(opts, :sort_dir, "desc")

    query =
      from(c in Creator)
      |> apply_creator_search_filter(Keyword.get(opts, :search_query, ""))
      |> apply_creator_badge_filter(Keyword.get(opts, :badge_level))
      |> apply_creator_tag_filter(Keyword.get(opts, :tag_ids))
      |> apply_outreach_status_filter(Keyword.get(opts, :outreach_status))

    total = Repo.aggregate(query, :count)

    creators =
      query
      |> apply_unified_sort(sort_by, sort_dir)
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

  defp apply_outreach_status_filter(query, nil), do: query
  defp apply_outreach_status_filter(query, ""), do: query

  defp apply_outreach_status_filter(query, status)
       when status in ["pending", "sent", "skipped", "unsubscribed"] do
    where(query, [c], c.outreach_status == ^status)
  end

  defp apply_outreach_status_filter(query, _), do: query

  # Unified sort supporting all columns from both CRM and Outreach modes
  defp apply_unified_sort(query, "sms_consent", "asc"),
    do: order_by(query, [c], asc_nulls_last: c.sms_consent)

  defp apply_unified_sort(query, "sms_consent", "desc"),
    do: order_by(query, [c], desc_nulls_last: c.sms_consent)

  defp apply_unified_sort(query, "added", "asc"),
    do: order_by(query, [c], asc: c.inserted_at)

  defp apply_unified_sort(query, "added", "desc"),
    do: order_by(query, [c], desc: c.inserted_at)

  defp apply_unified_sort(query, "sent", "asc"),
    do: order_by(query, [c], asc_nulls_last: c.outreach_sent_at)

  defp apply_unified_sort(query, "sent", "desc"),
    do: order_by(query, [c], desc_nulls_last: c.outreach_sent_at)

  defp apply_unified_sort(query, "status", "asc"),
    do: order_by(query, [c], asc_nulls_last: c.outreach_status)

  defp apply_unified_sort(query, "status", "desc"),
    do: order_by(query, [c], desc_nulls_last: c.outreach_status)

  # Enrichment columns
  defp apply_unified_sort(query, "enriched", "asc"),
    do: order_by(query, [c], asc_nulls_last: c.last_enriched_at)

  defp apply_unified_sort(query, "enriched", "desc"),
    do: order_by(query, [c], desc_nulls_first: c.last_enriched_at)

  defp apply_unified_sort(query, "video_gmv", "asc"),
    do: order_by(query, [c], asc_nulls_last: c.video_gmv_cents)

  defp apply_unified_sort(query, "video_gmv", "desc"),
    do: order_by(query, [c], desc_nulls_last: c.video_gmv_cents)

  defp apply_unified_sort(query, "avg_views", "asc"),
    do: order_by(query, [c], asc_nulls_last: c.avg_video_views)

  defp apply_unified_sort(query, "avg_views", "desc"),
    do: order_by(query, [c], desc_nulls_last: c.avg_video_views)

  # Delegate to existing sort handlers for CRM columns
  defp apply_unified_sort(query, sort_by, sort_dir),
    do: apply_creator_sort(query, sort_by, sort_dir)

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

  defp apply_creator_sort(query, "name", "asc"),
    do: order_by(query, [c], asc_nulls_last: c.first_name, asc_nulls_last: c.last_name)

  defp apply_creator_sort(query, "name", "desc"),
    do: order_by(query, [c], desc_nulls_last: c.first_name, desc_nulls_last: c.last_name)

  defp apply_creator_sort(query, "email", "asc"),
    do: order_by(query, [c], asc_nulls_last: c.email)

  defp apply_creator_sort(query, "email", "desc"),
    do: order_by(query, [c], desc_nulls_last: c.email)

  defp apply_creator_sort(query, "phone", "asc"),
    do: order_by(query, [c], asc_nulls_last: c.phone)

  defp apply_creator_sort(query, "phone", "desc"),
    do: order_by(query, [c], desc_nulls_last: c.phone)

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

  defp apply_creator_tag_filter(query, nil), do: query
  defp apply_creator_tag_filter(query, []), do: query

  defp apply_creator_tag_filter(query, tag_ids) do
    # Use subquery to avoid DISTINCT issues with ORDER BY on joined columns
    creator_ids_with_tags =
      from(cta in CreatorTagAssignment,
        where: cta.creator_tag_id in ^tag_ids,
        select: cta.creator_id
      )

    from(c in query,
      where: c.id in subquery(creator_ids_with_tags)
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
    videos_query =
      from(v in CreatorVideo, order_by: [desc: v.gmv_cents], preload: :video_products)

    Creator
    |> where([c], c.id == ^id)
    |> preload([
      :brands,
      :creator_tags,
      creator_samples: [:brand, product: :product_images],
      creator_videos: ^videos_query,
      performance_snapshots: []
    ])
    |> Repo.one!()
  end

  @doc """
  Gets a creator with minimal associations for modal header display.
  Only loads creator_tags, not samples/videos/performance data.
  """
  def get_creator_for_modal!(id) do
    Creator
    |> where([c], c.id == ^id)
    |> preload([:brands, :creator_tags])
    |> Repo.one!()
  end

  @doc """
  Gets samples for a creator with full associations for display.
  """
  def get_samples_for_modal(creator_id) do
    from(cs in CreatorSample,
      where: cs.creator_id == ^creator_id,
      order_by: [desc: cs.ordered_at],
      preload: [:brand, product: :product_images]
    )
    |> Repo.all()
  end

  @doc """
  Gets videos for a creator with associations for display.
  """
  def get_videos_for_modal(creator_id) do
    from(cv in CreatorVideo,
      where: cv.creator_id == ^creator_id,
      order_by: [desc: cv.gmv_cents],
      preload: [:video_products]
    )
    |> Repo.all()
  end

  @doc """
  Gets performance snapshots for a creator.
  """
  def get_performance_for_modal(creator_id) do
    from(ps in CreatorPerformanceSnapshot,
      where: ps.creator_id == ^creator_id,
      order_by: [desc: ps.snapshot_date]
    )
    |> Repo.all()
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

  @doc """
  Batch gets sample counts for multiple creators.
  Returns a map of creator_id => count.
  """
  def batch_count_samples(creator_ids) when is_list(creator_ids) do
    if creator_ids == [] do
      %{}
    else
      from(cs in CreatorSample,
        where: cs.creator_id in ^creator_ids,
        group_by: cs.creator_id,
        select: {cs.creator_id, count(cs.id)}
      )
      |> Repo.all()
      |> Map.new()
    end
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

  ## Sample Fulfillment

  @doc """
  Marks a sample as fulfilled by a video.
  Uses strict product matching - only auto-attributes if exact product_id matches.

  Returns {:ok, updated_sample} or {:error, reason}
  """
  def mark_sample_fulfilled(sample, video) do
    now = DateTime.utc_now()

    sample
    |> CreatorSample.changeset(%{
      fulfilled: true,
      fulfilled_at: now,
      attributed_video_id: video.id
    })
    |> Repo.update()
  end

  @doc """
  Attempts to auto-attribute a video to an unfulfilled sample using strict product matching.
  Only matches if the video's products include the sample's product_id.

  Returns {:ok, sample} if a match is found and attributed, or {:ok, nil} if no match.
  """
  def auto_attribute_video_to_sample(video) do
    # Get creator's unfulfilled samples
    unfulfilled_samples = get_unfulfilled_samples_for_creator(video.creator_id)

    # Get product IDs from this video
    video_product_ids = get_product_ids_for_video(video.id)

    # Find a sample that matches by product_id (strict match)
    matching_sample =
      Enum.find(unfulfilled_samples, fn sample ->
        sample.product_id && sample.product_id in video_product_ids
      end)

    if matching_sample do
      mark_sample_fulfilled(matching_sample, video)
    else
      {:ok, nil}
    end
  end

  @doc """
  Gets unfulfilled samples for a creator.
  """
  def get_unfulfilled_samples_for_creator(creator_id) do
    from(s in CreatorSample,
      where: s.creator_id == ^creator_id,
      where: s.fulfilled == false or is_nil(s.fulfilled),
      where: not is_nil(s.product_id),
      order_by: [desc: s.ordered_at]
    )
    |> Repo.all()
  end

  @doc """
  Gets product IDs linked to a video through video_products.
  """
  def get_product_ids_for_video(video_id) do
    from(vp in CreatorVideoProduct,
      where: vp.creator_video_id == ^video_id,
      where: not is_nil(vp.product_id),
      select: vp.product_id
    )
    |> Repo.all()
  end

  @doc """
  Gets fulfillment stats for a creator.
  Returns %{total_samples: n, fulfilled: n, unfulfilled: n, fulfillment_rate: float}
  Returns nil if the fulfillment columns don't exist yet (migration not run).
  """
  def get_fulfillment_stats(creator_id) do
    # Query just the count and fulfilled status to avoid loading full records
    # If the fulfilled column doesn't exist yet, catch the error and return nil
    total =
      from(s in CreatorSample, where: s.creator_id == ^creator_id, select: count())
      |> Repo.one()

    fulfilled =
      from(s in CreatorSample,
        where: s.creator_id == ^creator_id and s.fulfilled == true,
        select: count()
      )
      |> Repo.one()

    %{
      total_samples: total,
      fulfilled: fulfilled,
      unfulfilled: total - fulfilled,
      fulfillment_rate: if(total > 0, do: fulfilled / total, else: 0.0)
    }
  rescue
    Postgrex.Error ->
      # Column doesn't exist yet - migration hasn't been run
      nil
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

  ## BigQuery Sync Helpers

  @doc """
  Gets a creator by their TikTok user ID.
  Returns nil if not found or if user_id is nil/empty.
  """
  def get_creator_by_tiktok_user_id(nil), do: nil
  def get_creator_by_tiktok_user_id(""), do: nil

  def get_creator_by_tiktok_user_id(user_id) when is_binary(user_id) do
    from(c in Creator, where: c.tiktok_user_id == ^user_id, limit: 1)
    |> Repo.one()
  end

  @doc """
  Gets a creator by normalized phone number.
  Returns nil if not found or phone is nil/empty.
  """
  def get_creator_by_phone(nil), do: nil
  def get_creator_by_phone(""), do: nil

  def get_creator_by_phone(phone) when is_binary(phone) do
    normalized = normalize_phone(phone)

    if normalized do
      # Use limit 1 in case of duplicate phone numbers in DB
      from(c in Creator, where: c.phone == ^normalized, limit: 1)
      |> Repo.one()
    else
      nil
    end
  end

  @doc """
  Gets a creator by first and last name (case-insensitive).
  Returns nil if not found or names are empty.
  """
  def get_creator_by_name(nil, _), do: nil
  def get_creator_by_name("", _), do: nil

  def get_creator_by_name(first_name, last_name) do
    first_normalized = String.downcase(String.trim(first_name))
    last_normalized = if last_name, do: String.downcase(String.trim(last_name)), else: ""

    query =
      if last_normalized != "" do
        from(c in Creator,
          where:
            fragment("LOWER(?)", c.first_name) == ^first_normalized and
              fragment("LOWER(?)", c.last_name) == ^last_normalized,
          limit: 1
        )
      else
        from(c in Creator,
          where: fragment("LOWER(?)", c.first_name) == ^first_normalized,
          limit: 1
        )
      end

    Repo.one(query)
  end

  @doc """
  Gets all existing tiktok_order_ids for efficient filtering.
  Returns a MapSet for O(1) lookups.
  """
  def list_existing_order_ids do
    from(cs in CreatorSample,
      where: not is_nil(cs.tiktok_order_id),
      select: cs.tiktok_order_id,
      distinct: true
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Parses a full name into first and last name components.
  Returns {first_name, last_name} tuple.
  """
  def parse_name(nil), do: {nil, nil}
  def parse_name(""), do: {nil, nil}

  def parse_name(full_name) when is_binary(full_name) do
    parts = String.split(String.trim(full_name), " ", parts: 2)

    case parts do
      [first] -> {first, nil}
      [first, last] -> {first, last}
      _ -> {full_name, nil}
    end
  end

  ## Creator Tags

  @doc """
  Lists all tags for a brand, ordered by position.
  """
  def list_tags_for_brand(brand_id) do
    from(t in CreatorTag,
      where: t.brand_id == ^brand_id,
      order_by: [asc: t.position, asc: t.name]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single tag by ID.
  Raises `Ecto.NoResultsError` if not found.
  """
  def get_tag!(id), do: Repo.get!(CreatorTag, id)

  @doc """
  Gets a tag by ID, returns nil if not found.
  """
  def get_tag(id), do: Repo.get(CreatorTag, id)

  @doc """
  Gets a tag by name for a specific brand (case-insensitive).
  """
  def get_tag_by_name(brand_id, name) do
    normalized_name = String.downcase(String.trim(name))

    from(t in CreatorTag,
      where: t.brand_id == ^brand_id and fragment("LOWER(?)", t.name) == ^normalized_name
    )
    |> Repo.one()
  end

  @doc """
  Creates a new tag for a brand.
  Auto-assigns position if not provided.
  """
  def create_tag(attrs \\ %{}) do
    brand_id = attrs[:brand_id] || attrs["brand_id"]

    attrs =
      if Map.has_key?(attrs, :position) or Map.has_key?(attrs, "position") do
        attrs
      else
        max_position =
          from(t in CreatorTag,
            where: t.brand_id == ^brand_id,
            select: max(t.position)
          )
          |> Repo.one()

        Map.put(attrs, :position, (max_position || 0) + 1)
      end

    %CreatorTag{}
    |> CreatorTag.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a tag.
  """
  def update_tag(%CreatorTag{} = tag, attrs) do
    tag
    |> CreatorTag.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a tag. Also removes all assignments.
  """
  def delete_tag(%CreatorTag{} = tag) do
    Repo.delete(tag)
  end

  @doc """
  Counts how many creators have a specific tag assigned.
  """
  def count_creators_for_tag(tag_id) do
    from(a in CreatorTagAssignment, where: a.creator_tag_id == ^tag_id, select: count(a.id))
    |> Repo.one()
  end

  ## Tag Assignments

  @doc """
  Gets all tags assigned to a creator, optionally filtered by brand.
  """
  def list_tags_for_creator(creator_id, brand_id \\ nil) do
    query =
      from(t in CreatorTag,
        join: a in CreatorTagAssignment,
        on: a.creator_tag_id == t.id,
        where: a.creator_id == ^creator_id,
        order_by: [asc: t.position, asc: t.name]
      )

    query =
      if brand_id do
        where(query, [t], t.brand_id == ^brand_id)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Batch gets tags for multiple creators.
  Returns a map of creator_id => [tags].
  """
  def batch_list_tags_for_creators(creator_ids, brand_id) when is_list(creator_ids) do
    if creator_ids == [] do
      %{}
    else
      query =
        from(t in CreatorTag,
          join: a in CreatorTagAssignment,
          on: a.creator_tag_id == t.id,
          where: a.creator_id in ^creator_ids,
          order_by: [asc: t.position, asc: t.name],
          select: {a.creator_id, t}
        )

      query =
        if brand_id do
          where(query, [t], t.brand_id == ^brand_id)
        else
          query
        end

      query
      |> Repo.all()
      |> Enum.group_by(fn {creator_id, _tag} -> creator_id end, fn {_creator_id, tag} -> tag end)
    end
  end

  @doc """
  Assigns a tag to a creator. No-op if already assigned.
  Returns {:ok, assignment} or {:ok, :already_assigned}.
  """
  def assign_tag_to_creator(creator_id, tag_id) do
    attrs = %{creator_id: creator_id, creator_tag_id: tag_id}

    %CreatorTagAssignment{}
    |> CreatorTagAssignment.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing)
    |> case do
      {:ok, %{id: nil}} -> {:ok, :already_assigned}
      result -> result
    end
  end

  @doc """
  Removes a tag from a creator.
  Returns {:ok, count} where count is 0 or 1.
  """
  def remove_tag_from_creator(creator_id, tag_id) do
    {count, _} =
      from(a in CreatorTagAssignment,
        where: a.creator_id == ^creator_id and a.creator_tag_id == ^tag_id
      )
      |> Repo.delete_all()

    {:ok, count}
  end

  @doc """
  Sets the exact tags for a creator (replaces existing).
  """
  def set_creator_tags(creator_id, tag_ids) do
    Repo.transaction(fn ->
      # Delete existing assignments
      from(a in CreatorTagAssignment, where: a.creator_id == ^creator_id)
      |> Repo.delete_all()

      # Insert new assignments
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      entries =
        Enum.map(tag_ids, fn tag_id ->
          %{
            id: Ecto.UUID.generate(),
            creator_id: creator_id,
            creator_tag_id: tag_id,
            inserted_at: now,
            updated_at: now
          }
        end)

      {count, _} = Repo.insert_all(CreatorTagAssignment, entries)
      count
    end)
  end

  @doc """
  Batch assigns tags to multiple creators (merge, don't replace).
  Returns {:ok, count} of assignments created.
  """
  def batch_assign_tags(creator_ids, tag_ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      for creator_id <- creator_ids, tag_id <- tag_ids do
        %{
          id: Ecto.UUID.generate(),
          creator_id: creator_id,
          creator_tag_id: tag_id,
          inserted_at: now,
          updated_at: now
        }
      end

    {count, _} = Repo.insert_all(CreatorTagAssignment, entries, on_conflict: :nothing)
    {:ok, count}
  end

  @doc """
  Gets tag IDs for a creator.
  """
  def get_tag_ids_for_creator(creator_id) do
    from(a in CreatorTagAssignment,
      where: a.creator_id == ^creator_id,
      select: a.creator_tag_id
    )
    |> Repo.all()
  end

  ## Creator Purchases

  @doc """
  Creates a creator purchase record.
  Uses on_conflict: :nothing to handle duplicates gracefully.
  """
  def create_purchase(attrs \\ %{}) do
    %CreatorPurchase{}
    |> CreatorPurchase.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :tiktok_order_id)
  end

  @doc """
  Lists purchases for a creator, ordered by date descending.
  """
  def list_purchases_for_creator(creator_id) do
    from(p in CreatorPurchase,
      where: p.creator_id == ^creator_id,
      order_by: [desc: p.ordered_at]
    )
    |> Repo.all()
  end

  @doc """
  Gets purchase statistics for a creator.
  Returns %{purchase_count: n, total_spent_cents: n, paid_purchase_count: n}
  """
  def get_purchase_stats(creator_id) do
    from(p in CreatorPurchase,
      where: p.creator_id == ^creator_id,
      select: %{
        purchase_count: count(p.id),
        total_spent_cents: coalesce(sum(p.total_amount_cents), 0)
      }
    )
    |> Repo.one()
    |> then(fn stats ->
      # Also count non-sample (paid) purchases
      paid_count =
        from(p in CreatorPurchase,
          where: p.creator_id == ^creator_id and p.is_sample_order == false,
          select: count(p.id)
        )
        |> Repo.one()

      Map.put(stats, :paid_purchase_count, paid_count)
    end)
  end

  @doc """
  Gets purchases for a creator for modal display, limited to 50.
  """
  def get_purchases_for_modal(creator_id) do
    from(p in CreatorPurchase,
      where: p.creator_id == ^creator_id,
      order_by: [desc: p.ordered_at],
      limit: 50
    )
    |> Repo.all()
  end

  @doc """
  Lists all existing purchase order IDs for efficient deduplication.
  Returns a MapSet for O(1) lookups.
  """
  def list_existing_purchase_order_ids do
    from(p in CreatorPurchase,
      select: p.tiktok_order_id,
      distinct: true
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Batch counts purchases for multiple creators.
  Returns a map of creator_id => count.
  """
  def batch_count_purchases(creator_ids) when is_list(creator_ids) do
    if creator_ids == [] do
      %{}
    else
      from(p in CreatorPurchase,
        where: p.creator_id in ^creator_ids and p.is_sample_order == false,
        group_by: p.creator_id,
        select: {p.creator_id, count(p.id)}
      )
      |> Repo.all()
      |> Map.new()
    end
  end
end
