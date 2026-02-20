defmodule SocialObjects.Creators do
  @moduledoc """
  The Creators context handles creator/affiliate CRM functionality.

  This context manages creators, their brand relationships, product samples,
  video content, and performance tracking.
  """

  import Ecto.Query, warn: false
  alias SocialObjects.Repo

  alias SocialObjects.Creators.{
    BrandCreator,
    Creator,
    CreatorPerformanceSnapshot,
    CreatorPurchase,
    CreatorSample,
    CreatorTag,
    CreatorTagAssignment,
    CreatorVideo,
    CreatorVideoMetricSnapshot,
    CreatorVideoProduct
  }

  ## Creators

  @spec list_creators() :: [Creator.t()]
  @doc """
  Returns the list of creators.
  """
  def list_creators do
    Repo.all(Creator)
  end

  @spec search_creators_paginated(keyword()) :: %{
          creators: [Creator.t()],
          total: non_neg_integer(),
          page: pos_integer(),
          per_page: pos_integer(),
          has_more: boolean()
        }
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
    brand_id = Keyword.get(opts, :brand_id)

    query =
      from(c in Creator)
      |> apply_creator_search_filter(Keyword.get(opts, :search_query, ""))
      |> apply_creator_badge_filter(Keyword.get(opts, :badge_level))
      |> apply_creator_tag_filter(Keyword.get(opts, :tag_ids))
      |> apply_creator_brand_filter(brand_id)

    total = Repo.aggregate(query, :count)

    creators =
      query
      |> apply_creator_sort(sort_by, sort_dir, brand_id)
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

  @spec search_creators_unified(keyword()) :: %{
          creators: [Creator.t()],
          total: non_neg_integer(),
          page: pos_integer(),
          per_page: pos_integer(),
          has_more: boolean()
        }
  @doc """
  Unified search for creators with all filters from both CRM and Outreach modes.

  ## Options
    - search_query: Search by username, email, first/last name
    - badge_level: Filter by TikTok badge level
    - tag_ids: Filter by tag IDs
    - outreach_status: Filter by contact status (nil = all, or "never_contacted"/"contacted"/"opted_out")
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
    brand_id = Keyword.get(opts, :brand_id)

    query =
      from(c in Creator)
      |> apply_creator_search_filter(Keyword.get(opts, :search_query, ""))
      |> apply_creator_badge_filter(Keyword.get(opts, :badge_level))
      |> apply_creator_tag_filter(Keyword.get(opts, :tag_ids))
      |> apply_outreach_status_filter(Keyword.get(opts, :outreach_status), brand_id)
      |> apply_segment_filter(Keyword.get(opts, :segment), brand_id)
      |> apply_last_touchpoint_type_filter(Keyword.get(opts, :last_touchpoint_type), brand_id)
      |> apply_preferred_contact_channel_filter(
        Keyword.get(opts, :preferred_contact_channel),
        brand_id
      )
      |> apply_next_touchpoint_state_filter(Keyword.get(opts, :next_touchpoint_state), brand_id)
      |> apply_added_after_filter(Keyword.get(opts, :added_after))
      |> apply_added_before_filter(Keyword.get(opts, :added_before))
      |> apply_creator_brand_filter(brand_id)

    total = Repo.aggregate(query, :count)

    creators =
      query
      |> apply_unified_sort(sort_by, sort_dir, brand_id)
      |> order_by([c], asc: c.id)
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

  @spec get_creator_segment_stats(pos_integer()) :: %{
          total: non_neg_integer(),
          vip: non_neg_integer(),
          trending: non_neg_integer(),
          high_priority: non_neg_integer(),
          needs_attention: non_neg_integer()
        }
  def get_creator_segment_stats(brand_id) do
    from(bc in BrandCreator,
      where: bc.brand_id == ^brand_id,
      select: %{
        total: count(bc.id),
        vip: fragment("COALESCE(SUM(CASE WHEN ? THEN 1 ELSE 0 END), 0)", bc.is_vip),
        trending: fragment("COALESCE(SUM(CASE WHEN ? THEN 1 ELSE 0 END), 0)", bc.is_trending),
        high_priority:
          fragment(
            "COALESCE(SUM(CASE WHEN ? = 'high' THEN 1 ELSE 0 END), 0)",
            bc.engagement_priority
          ),
        needs_attention:
          fragment(
            "COALESCE(SUM(CASE WHEN ? = 'monitor' THEN 1 ELSE 0 END), 0)",
            bc.engagement_priority
          )
      }
    )
    |> Repo.one()
  end

  defp apply_outreach_status_filter(query, nil, _brand_id), do: query
  defp apply_outreach_status_filter(query, "", _brand_id), do: query

  # New contact-based status filters
  defp apply_outreach_status_filter(query, "never_contacted", nil) do
    # Creators with no email outreach logs and not opted out (no brand filter)
    from(c in query,
      left_join: ol in SocialObjects.Outreach.OutreachLog,
      on: ol.creator_id == c.id and ol.channel == :email,
      where: is_nil(ol.id),
      where: c.email_opted_out == false
    )
  end

  defp apply_outreach_status_filter(query, "never_contacted", brand_id) do
    # Creators with no email outreach logs and not opted out (for specific brand)
    from(c in query,
      left_join: ol in SocialObjects.Outreach.OutreachLog,
      on: ol.creator_id == c.id and ol.channel == :email and ol.brand_id == ^brand_id,
      where: is_nil(ol.id),
      where: c.email_opted_out == false
    )
  end

  defp apply_outreach_status_filter(query, "contacted", nil) do
    # Creators with at least one email outreach log and not opted out (no brand filter)
    from(c in query,
      join: ol in SocialObjects.Outreach.OutreachLog,
      on: ol.creator_id == c.id and ol.channel == :email,
      where: c.email_opted_out == false,
      distinct: true
    )
  end

  defp apply_outreach_status_filter(query, "contacted", brand_id) do
    # Creators with at least one email outreach log and not opted out (for specific brand)
    from(c in query,
      join: ol in SocialObjects.Outreach.OutreachLog,
      on: ol.creator_id == c.id and ol.channel == :email and ol.brand_id == ^brand_id,
      where: c.email_opted_out == false,
      distinct: true
    )
  end

  defp apply_outreach_status_filter(query, "opted_out", _brand_id) do
    where(query, [c], c.email_opted_out == true)
  end

  defp apply_outreach_status_filter(query, "sampled", brand_id) do
    # Creators who have received at least one sample
    sampled_creator_ids =
      from(cs in CreatorSample,
        select: cs.creator_id,
        distinct: true
      )
      |> maybe_filter_by_brand(:brand_id, brand_id)

    from(c in query, where: c.id in subquery(sampled_creator_ids))
  end

  defp apply_outreach_status_filter(query, _, _brand_id), do: query

  defp apply_segment_filter(query, nil, _brand_id), do: query
  defp apply_segment_filter(query, "", _brand_id), do: query
  defp apply_segment_filter(query, _segment, nil), do: query

  defp apply_segment_filter(query, "vip", brand_id) do
    creator_ids_query =
      from(bc in BrandCreator,
        where: bc.brand_id == ^brand_id and bc.is_vip == true,
        select: bc.creator_id
      )

    from(c in query, where: c.id in subquery(creator_ids_query))
  end

  defp apply_segment_filter(query, "trending", brand_id) do
    creator_ids_query =
      from(bc in BrandCreator,
        where: bc.brand_id == ^brand_id and bc.is_trending == true,
        select: bc.creator_id
      )

    from(c in query, where: c.id in subquery(creator_ids_query))
  end

  defp apply_segment_filter(query, "high_priority", brand_id) do
    creator_ids_query =
      from(bc in BrandCreator,
        where: bc.brand_id == ^brand_id and bc.engagement_priority == :high,
        select: bc.creator_id
      )

    from(c in query, where: c.id in subquery(creator_ids_query))
  end

  defp apply_segment_filter(query, "needs_attention", brand_id) do
    creator_ids_query =
      from(bc in BrandCreator,
        where: bc.brand_id == ^brand_id and bc.engagement_priority == :monitor,
        select: bc.creator_id
      )

    from(c in query, where: c.id in subquery(creator_ids_query))
  end

  defp apply_segment_filter(query, _segment, _brand_id), do: query

  defp apply_last_touchpoint_type_filter(query, nil, _brand_id), do: query
  defp apply_last_touchpoint_type_filter(query, "", _brand_id), do: query
  defp apply_last_touchpoint_type_filter(query, _type, nil), do: query

  defp apply_last_touchpoint_type_filter(query, type, brand_id) do
    case type do
      "email" ->
        creator_ids_query =
          from(bc in BrandCreator,
            where: bc.brand_id == ^brand_id and bc.last_touchpoint_type == :email,
            select: bc.creator_id
          )

        from(c in query, where: c.id in subquery(creator_ids_query))

      "sms" ->
        creator_ids_query =
          from(bc in BrandCreator,
            where: bc.brand_id == ^brand_id and bc.last_touchpoint_type == :sms,
            select: bc.creator_id
          )

        from(c in query, where: c.id in subquery(creator_ids_query))

      "manual" ->
        creator_ids_query =
          from(bc in BrandCreator,
            where: bc.brand_id == ^brand_id and bc.last_touchpoint_type == :manual,
            select: bc.creator_id
          )

        from(c in query, where: c.id in subquery(creator_ids_query))

      _ ->
        query
    end
  end

  defp apply_preferred_contact_channel_filter(query, nil, _brand_id), do: query
  defp apply_preferred_contact_channel_filter(query, "", _brand_id), do: query
  defp apply_preferred_contact_channel_filter(query, _channel, nil), do: query

  defp apply_preferred_contact_channel_filter(query, channel, brand_id) do
    case channel do
      "email" ->
        creator_ids_query =
          from(bc in BrandCreator,
            where: bc.brand_id == ^brand_id and bc.preferred_contact_channel == :email,
            select: bc.creator_id
          )

        from(c in query, where: c.id in subquery(creator_ids_query))

      "sms" ->
        creator_ids_query =
          from(bc in BrandCreator,
            where: bc.brand_id == ^brand_id and bc.preferred_contact_channel == :sms,
            select: bc.creator_id
          )

        from(c in query, where: c.id in subquery(creator_ids_query))

      "tiktok_dm" ->
        creator_ids_query =
          from(bc in BrandCreator,
            where: bc.brand_id == ^brand_id and bc.preferred_contact_channel == :tiktok_dm,
            select: bc.creator_id
          )

        from(c in query, where: c.id in subquery(creator_ids_query))

      _ ->
        query
    end
  end

  defp apply_next_touchpoint_state_filter(query, nil, _brand_id), do: query
  defp apply_next_touchpoint_state_filter(query, "", _brand_id), do: query
  defp apply_next_touchpoint_state_filter(query, _state, nil), do: query

  defp apply_next_touchpoint_state_filter(query, state, brand_id) do
    case next_touchpoint_creator_ids_query(state, brand_id) do
      nil -> query
      creator_ids_query -> from(c in query, where: c.id in subquery(creator_ids_query))
    end
  end

  defp next_touchpoint_creator_ids_query("scheduled", brand_id) do
    now = touchpoint_filter_now()

    from(bc in BrandCreator,
      where: bc.brand_id == ^brand_id,
      where: not is_nil(bc.next_touchpoint_at) and bc.next_touchpoint_at >= ^now,
      select: bc.creator_id
    )
  end

  defp next_touchpoint_creator_ids_query("due_this_week", brand_id) do
    now = touchpoint_filter_now()
    week_window_end = DateTime.add(now, 7 * 86_400, :second)

    from(bc in BrandCreator,
      where: bc.brand_id == ^brand_id,
      where:
        not is_nil(bc.next_touchpoint_at) and bc.next_touchpoint_at >= ^now and
          bc.next_touchpoint_at < ^week_window_end,
      select: bc.creator_id
    )
  end

  defp next_touchpoint_creator_ids_query("overdue", brand_id) do
    now = touchpoint_filter_now()

    from(bc in BrandCreator,
      where: bc.brand_id == ^brand_id,
      where: not is_nil(bc.next_touchpoint_at) and bc.next_touchpoint_at < ^now,
      select: bc.creator_id
    )
  end

  defp next_touchpoint_creator_ids_query("unscheduled", brand_id) do
    from(bc in BrandCreator,
      where: bc.brand_id == ^brand_id and is_nil(bc.next_touchpoint_at),
      select: bc.creator_id
    )
  end

  defp next_touchpoint_creator_ids_query(_, _brand_id), do: nil

  defp touchpoint_filter_now do
    DateTime.utc_now() |> DateTime.truncate(:second)
  end

  # Helper to conditionally filter by brand_id without causing PostgreSQL type inference issues
  defp maybe_filter_by_brand(query, _field, nil), do: query

  defp maybe_filter_by_brand(query, :brand_id, brand_id),
    do: where(query, [q], q.brand_id == ^brand_id)

  defp apply_added_after_filter(query, nil), do: query

  defp apply_added_after_filter(query, %Date{} = date) do
    datetime = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    where(query, [c], c.inserted_at >= ^datetime)
  end

  defp apply_added_after_filter(query, date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> apply_added_after_filter(query, date)
      {:error, _} -> query
    end
  end

  defp apply_added_before_filter(query, nil), do: query

  defp apply_added_before_filter(query, %Date{} = date) do
    # End of day for the "before" date
    datetime = DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC")
    where(query, [c], c.inserted_at < ^datetime)
  end

  defp apply_added_before_filter(query, date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> apply_added_before_filter(query, date)
      {:error, _} -> query
    end
  end

  # Unified sort supporting all columns from both CRM and Outreach modes
  defp apply_unified_sort(query, "sms_consent", "asc", _brand_id),
    do: order_by(query, [c], asc_nulls_last: c.sms_consent)

  defp apply_unified_sort(query, "sms_consent", "desc", _brand_id),
    do: order_by(query, [c], desc_nulls_last: c.sms_consent)

  defp apply_unified_sort(query, "added", "asc", _brand_id),
    do: order_by(query, [c], asc: c.inserted_at)

  defp apply_unified_sort(query, "added", "desc", _brand_id),
    do: order_by(query, [c], desc: c.inserted_at)

  defp apply_unified_sort(query, "sent", "asc", _brand_id),
    do: order_by(query, [c], asc_nulls_last: c.outreach_sent_at)

  defp apply_unified_sort(query, "sent", "desc", _brand_id),
    do: order_by(query, [c], desc_nulls_last: c.outreach_sent_at)

  # Enrichment columns
  defp apply_unified_sort(query, "enriched", "asc", _brand_id),
    do: order_by(query, [c], asc_nulls_last: c.last_enriched_at)

  defp apply_unified_sort(query, "enriched", "desc", _brand_id),
    do: order_by(query, [c], desc_nulls_first: c.last_enriched_at)

  defp apply_unified_sort(query, "video_gmv", "asc", _brand_id),
    do: order_by(query, [c], asc_nulls_last: c.video_gmv_cents)

  defp apply_unified_sort(query, "video_gmv", "desc", _brand_id),
    do: order_by(query, [c], desc_nulls_last: c.video_gmv_cents)

  defp apply_unified_sort(query, "avg_views", "asc", _brand_id),
    do: order_by(query, [c], asc_nulls_last: c.avg_video_views)

  defp apply_unified_sort(query, "avg_views", "desc", _brand_id),
    do: order_by(query, [c], desc_nulls_last: c.avg_video_views)

  # Cumulative GMV sorting
  defp apply_unified_sort(query, "cumulative_gmv", "asc", _brand_id),
    do: order_by(query, [c], asc_nulls_last: c.cumulative_gmv_cents)

  defp apply_unified_sort(query, "cumulative_gmv", "desc", _brand_id),
    do: order_by(query, [c], desc_nulls_last: c.cumulative_gmv_cents)

  # Brand GMV sorting (from brand_creators junction table)
  defp apply_unified_sort(query, "brand_gmv", dir, brand_id) do
    query
    |> join(:left, [c], bc in BrandCreator,
      on: bc.creator_id == c.id and bc.brand_id == ^brand_id,
      as: :brand_creator_gmv
    )
    |> order_by([brand_creator_gmv: bc], [{^sort_dir_nulls_last(dir), bc.brand_gmv_cents}])
  end

  defp apply_unified_sort(query, "cumulative_brand_gmv", dir, brand_id) do
    query
    |> join(:left, [c], bc in BrandCreator,
      on: bc.creator_id == c.id and bc.brand_id == ^brand_id,
      as: :brand_creator_cumulative_gmv
    )
    |> order_by([brand_creator_cumulative_gmv: bc], [
      {^sort_dir_nulls_last(dir), bc.cumulative_brand_gmv_cents}
    ])
  end

  defp apply_unified_sort(query, "last_touchpoint", dir, brand_id) do
    query
    |> join(:left, [c], bc in BrandCreator,
      on: bc.creator_id == c.id and bc.brand_id == ^brand_id,
      as: :brand_creator_last_touchpoint
    )
    |> order_by([brand_creator_last_touchpoint: bc], [
      {^sort_dir_nulls_last(dir), bc.last_touchpoint_at}
    ])
  end

  defp apply_unified_sort(query, "next_touchpoint", dir, brand_id) do
    query
    |> join(:left, [c], bc in BrandCreator,
      on: bc.creator_id == c.id and bc.brand_id == ^brand_id,
      as: :brand_creator_next_touchpoint
    )
    |> order_by([brand_creator_next_touchpoint: bc], [
      {^sort_dir_nulls_last(dir), bc.next_touchpoint_at}
    ])
  end

  defp apply_unified_sort(query, "priority", dir, brand_id) do
    query
    |> join(:left, [c], bc in BrandCreator,
      on: bc.creator_id == c.id and bc.brand_id == ^brand_id,
      as: :brand_creator_priority
    )
    |> order_by([brand_creator_priority: bc], [
      {^sort_dir_nulls_last(dir), bc.engagement_priority}
    ])
  end

  # Delegate to existing sort handlers for CRM columns
  defp apply_unified_sort(query, sort_by, sort_dir, brand_id),
    do: apply_creator_sort(query, sort_by, sort_dir, brand_id)

  defp apply_creator_sort(query, "username", "asc", _brand_id),
    do: order_by(query, [c], asc: c.tiktok_username)

  defp apply_creator_sort(query, "username", "desc", _brand_id),
    do: order_by(query, [c], desc: c.tiktok_username)

  defp apply_creator_sort(query, "followers", "desc", _brand_id),
    do: order_by(query, [c], desc_nulls_last: c.follower_count)

  defp apply_creator_sort(query, "followers", "asc", _brand_id),
    do: order_by(query, [c], asc_nulls_last: c.follower_count)

  defp apply_creator_sort(query, "gmv", "desc", _brand_id),
    do: order_by(query, [c], desc_nulls_last: c.total_gmv_cents)

  defp apply_creator_sort(query, "gmv", "asc", _brand_id),
    do: order_by(query, [c], asc_nulls_last: c.total_gmv_cents)

  defp apply_creator_sort(query, "videos", "desc", _brand_id),
    do: order_by(query, [c], desc_nulls_last: c.total_videos)

  defp apply_creator_sort(query, "videos", "asc", _brand_id),
    do: order_by(query, [c], asc_nulls_last: c.total_videos)

  # Note: videos_posted and commission are computed from creator_videos table via subquery
  # Uses named bindings (as:) to avoid conflicts with other joins in the query
  defp apply_creator_sort(query, "videos_posted", dir, brand_id) do
    video_counts =
      CreatorVideo
      |> maybe_filter_brand(brand_id)
      |> group_by([cv], cv.creator_id)
      |> select([cv], %{creator_id: cv.creator_id, count: count(cv.id)})

    query
    |> join(:left, [c], vc in subquery(video_counts),
      on: vc.creator_id == c.id,
      as: :video_counts
    )
    |> order_by([video_counts: vc], [{^sort_dir_atom(dir), coalesce(vc.count, 0)}])
  end

  defp apply_creator_sort(query, "commission", dir, brand_id) do
    commission_sums =
      CreatorVideo
      |> maybe_filter_brand(brand_id)
      |> group_by([cv], cv.creator_id)
      |> select([cv], %{
        creator_id: cv.creator_id,
        total: coalesce(sum(cv.est_commission_cents), 0)
      })

    query
    |> join(:left, [c], cs in subquery(commission_sums),
      on: cs.creator_id == c.id,
      as: :commission_sums
    )
    |> order_by([commission_sums: cs], [{^sort_dir_atom(dir), coalesce(cs.total, 0)}])
  end

  defp apply_creator_sort(query, "name", "asc", _brand_id),
    do: order_by(query, [c], asc_nulls_last: c.first_name, asc_nulls_last: c.last_name)

  defp apply_creator_sort(query, "name", "desc", _brand_id),
    do: order_by(query, [c], desc_nulls_last: c.first_name, desc_nulls_last: c.last_name)

  defp apply_creator_sort(query, "email", "asc", _brand_id),
    do: order_by(query, [c], asc_nulls_last: c.email)

  defp apply_creator_sort(query, "email", "desc", _brand_id),
    do: order_by(query, [c], desc_nulls_last: c.email)

  defp apply_creator_sort(query, "phone", "asc", _brand_id),
    do: order_by(query, [c], asc_nulls_last: c.phone)

  defp apply_creator_sort(query, "phone", "desc", _brand_id),
    do: order_by(query, [c], desc_nulls_last: c.phone)

  defp apply_creator_sort(query, "samples", dir, brand_id) do
    sample_counts =
      CreatorSample
      |> maybe_filter_brand(brand_id)
      |> group_by([cs], cs.creator_id)
      |> select([cs], %{creator_id: cs.creator_id, count: count(cs.id)})

    query
    |> join(:left, [c], sc in subquery(sample_counts),
      on: sc.creator_id == c.id,
      as: :sample_counts
    )
    |> order_by([sample_counts: sc], [{^sort_dir_atom(dir), coalesce(sc.count, 0)}])
  end

  defp apply_creator_sort(query, "last_sample", dir, brand_id) do
    last_sample_dates =
      CreatorSample
      |> maybe_filter_brand(brand_id)
      |> group_by([cs], cs.creator_id)
      |> select([cs], %{creator_id: cs.creator_id, last_at: max(cs.ordered_at)})

    query
    |> join(:left, [c], ls in subquery(last_sample_dates),
      on: ls.creator_id == c.id,
      as: :last_sample
    )
    |> order_by([last_sample: ls], [{^sort_dir_nulls_last(dir), ls.last_at}])
  end

  defp apply_creator_sort(query, _, _, _brand_id),
    do: order_by(query, [c], asc: c.tiktok_username)

  defp sort_dir_atom("desc"), do: :desc
  defp sort_dir_atom(_), do: :asc

  defp sort_dir_nulls_last("desc"), do: :desc_nulls_last
  defp sort_dir_nulls_last(_), do: :asc_nulls_last

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
        ilike(c.last_name, ^pattern) or
        fragment(
          "EXISTS (SELECT 1 FROM unnest(?) AS prev WHERE prev ILIKE ?)",
          c.previous_tiktok_usernames,
          ^pattern
        )
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

  defp maybe_filter_brand(query, nil), do: query

  defp maybe_filter_brand(query, brand_id),
    do: where(query, [q], field(q, :brand_id) == ^brand_id)

  @spec get_creator!(pos_integer()) :: Creator.t() | no_return()
  @doc """
  Gets a single creator.
  Raises `Ecto.NoResultsError` if the Creator does not exist.
  """
  def get_creator!(id), do: Repo.get!(Creator, id)

  @spec get_creator!(pos_integer(), pos_integer()) :: Creator.t() | no_return()
  def get_creator!(brand_id, id) do
    Creator
    |> join(:inner, [c], bc in BrandCreator, on: bc.creator_id == c.id)
    |> where([c, bc], c.id == ^id and bc.brand_id == ^brand_id)
    |> Repo.one!()
  end

  @spec get_creator_by_username(String.t()) :: Creator.t() | nil
  @doc """
  Gets a creator by TikTok username (case-insensitive).
  Returns nil if not found.
  """
  def get_creator_by_username(username) when is_binary(username) do
    normalized = String.downcase(String.trim(username))
    Repo.get_by(Creator, tiktok_username: normalized)
  end

  @spec get_creator_with_details!(pos_integer()) :: Creator.t() | no_return()
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

  @spec get_creator_with_details!(pos_integer(), pos_integer()) :: Creator.t() | no_return()
  def get_creator_with_details!(brand_id, id) do
    videos_query =
      from(v in CreatorVideo, order_by: [desc: v.gmv_cents], preload: :video_products)

    Creator
    |> join(:inner, [c], bc in BrandCreator, on: bc.creator_id == c.id)
    |> where([c, bc], c.id == ^id and bc.brand_id == ^brand_id)
    |> preload([
      :brands,
      :creator_tags,
      creator_samples: [:brand, product: :product_images],
      creator_videos: ^videos_query,
      performance_snapshots: []
    ])
    |> Repo.one!()
  end

  @spec get_creator_for_modal!(pos_integer()) :: Creator.t() | no_return()
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

  @spec get_creator_for_modal!(pos_integer(), pos_integer()) :: Creator.t() | no_return()
  def get_creator_for_modal!(brand_id, id) do
    query =
      from c in Creator,
        join: bc in BrandCreator,
        on: bc.creator_id == c.id,
        where: c.id == ^id and bc.brand_id == ^brand_id,
        select: {c, bc}

    {creator, brand_creator} = Repo.one!(query)

    creator
    |> Repo.preload([:brands, :creator_tags])
    # Override creator metrics with brand-specific values
    |> Map.put(:cumulative_gmv_cents, brand_creator.cumulative_brand_gmv_cents)
    |> Map.put(:total_gmv_cents, brand_creator.brand_gmv_cents)
    |> Map.put(:gmv_tracking_started_at, brand_creator.brand_gmv_tracking_started_at)
    |> Map.put(:video_count, brand_creator.video_count)
    |> Map.put(:live_count, brand_creator.live_count)
  end

  @spec get_samples_for_modal(pos_integer()) :: [CreatorSample.t()]
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

  @spec get_samples_for_modal(pos_integer(), pos_integer()) :: [CreatorSample.t()]
  def get_samples_for_modal(brand_id, creator_id) do
    from(cs in CreatorSample,
      where: cs.brand_id == ^brand_id and cs.creator_id == ^creator_id,
      order_by: [desc: cs.ordered_at],
      preload: [:brand, product: :product_images]
    )
    |> Repo.all()
  end

  @spec get_videos_for_modal(pos_integer()) :: [CreatorVideo.t()]
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

  @spec get_videos_for_modal(pos_integer(), pos_integer()) :: [CreatorVideo.t()]
  def get_videos_for_modal(brand_id, creator_id) do
    from(cv in CreatorVideo,
      where: cv.brand_id == ^brand_id and cv.creator_id == ^creator_id,
      order_by: [desc: cv.gmv_cents],
      preload: [:video_products]
    )
    |> Repo.all()
  end

  @spec get_performance_for_modal(pos_integer()) :: [CreatorPerformanceSnapshot.t()]
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

  @spec get_performance_for_modal(pos_integer(), pos_integer()) :: [
          CreatorPerformanceSnapshot.t()
        ]
  def get_performance_for_modal(brand_id, creator_id) do
    from(ps in CreatorPerformanceSnapshot,
      where: ps.brand_id == ^brand_id and ps.creator_id == ^creator_id,
      order_by: [desc: ps.snapshot_date]
    )
    |> Repo.all()
  end

  @spec create_creator(map()) :: {:ok, Creator.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Creates a creator.
  """
  def create_creator(attrs \\ %{}) do
    %Creator{}
    |> Creator.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_creator(Creator.t(), map()) :: {:ok, Creator.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Updates a creator.
  """
  def update_creator(%Creator{} = creator, attrs) do
    creator
    |> Creator.changeset(attrs)
    |> Repo.update()
  end

  @spec update_creator_contact(Creator.t(), map(), DateTime.t()) ::
          {:ok, Creator.t()} | {:error, Ecto.Changeset.t()} | {:error, :stale_entry}
  @doc """
  Updates creator contact info with optimistic locking.

  Takes a `lock_updated_at` timestamp that must match the creator's current
  `updated_at` to proceed. Returns:
  - `{:ok, creator}` on success
  - `{:error, :stale_entry}` if the record was modified since lock was acquired
  - `{:error, changeset}` if validation fails

  Automatically tracks which fields were edited in `manually_edited_fields`.
  """
  def update_creator_contact(%Creator{} = creator, attrs, lock_updated_at) do
    case Creator.contact_changeset(creator, attrs, lock_updated_at) do
      {:ok, changeset} -> Repo.update(changeset)
      {:error, :stale_entry} -> {:error, :stale_entry}
    end
  end

  @spec delete_creator(Creator.t()) :: {:ok, Creator.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Deletes a creator.
  """
  def delete_creator(%Creator{} = creator) do
    Repo.delete(creator)
  end

  @spec upsert_creator(map()) :: {:ok, Creator.t()} | {:error, Ecto.Changeset.t()}
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

  @spec normalize_phone(String.t() | nil) :: String.t() | nil
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

  @spec count_creators() :: non_neg_integer()
  @doc """
  Returns the count of creators.
  """
  def count_creators do
    Repo.aggregate(Creator, :count)
  end

  @spec count_creators_for_brand(pos_integer()) :: non_neg_integer()
  @doc """
  Returns the count of creators associated with a brand.
  """
  def count_creators_for_brand(brand_id) do
    from(bc in BrandCreator,
      where: bc.brand_id == ^brand_id,
      select: count(bc.creator_id, :distinct)
    )
    |> Repo.one()
  end

  ## Brand-Creator Relationships

  @spec list_brands_with_creators() :: [SocialObjects.Catalog.Brand.t()]
  @doc """
  Lists brands that have at least one creator associated.
  Returns Brand structs.
  """
  def list_brands_with_creators do
    from(b in SocialObjects.Catalog.Brand,
      join: bc in BrandCreator,
      on: bc.brand_id == b.id,
      distinct: true,
      order_by: [asc: b.name]
    )
    |> Repo.all()
  end

  @spec add_creator_to_brand(pos_integer(), pos_integer(), map()) ::
          {:ok, BrandCreator.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Associates a creator with a brand.
  """
  def add_creator_to_brand(creator_id, brand_id, attrs \\ %{}) do
    %BrandCreator{}
    |> BrandCreator.changeset(Map.merge(attrs, %{creator_id: creator_id, brand_id: brand_id}))
    |> Repo.insert(on_conflict: :nothing)
  end

  @spec list_brands_for_creator(pos_integer()) :: [SocialObjects.Catalog.Brand.t()]
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

  @spec get_brand_creator(pos_integer(), pos_integer()) :: BrandCreator.t() | nil
  @doc """
  Gets the brand_creator junction record for a brand/creator pair.
  Returns nil if no association exists.
  """
  def get_brand_creator(brand_id, creator_id) do
    Repo.get_by(BrandCreator, brand_id: brand_id, creator_id: creator_id)
  end

  @spec update_brand_creator(BrandCreator.t(), map()) ::
          {:ok, BrandCreator.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Updates a brand_creator record.
  """
  def update_brand_creator(%BrandCreator{} = brand_creator, attrs) do
    brand_creator
    |> BrandCreator.changeset(attrs)
    |> Repo.update()
  end

  @spec batch_load_brand_creator_fields(pos_integer(), [pos_integer()]) :: %{
          optional(pos_integer()) => map()
        }
  def batch_load_brand_creator_fields(brand_id, creator_ids) when is_list(creator_ids) do
    if creator_ids == [] do
      %{}
    else
      from(bc in BrandCreator,
        where: bc.brand_id == ^brand_id and bc.creator_id in ^creator_ids,
        select:
          {bc.creator_id,
           %{
             brand_gmv_cents: bc.brand_gmv_cents,
             brand_video_gmv_cents: bc.brand_video_gmv_cents,
             brand_live_gmv_cents: bc.brand_live_gmv_cents,
             cumulative_brand_gmv_cents: bc.cumulative_brand_gmv_cents,
             cumulative_brand_video_gmv_cents: bc.cumulative_brand_video_gmv_cents,
             cumulative_brand_live_gmv_cents: bc.cumulative_brand_live_gmv_cents,
             brand_gmv_tracking_started_at: bc.brand_gmv_tracking_started_at,
             video_count: bc.video_count,
             live_count: bc.live_count,
             last_touchpoint_at: bc.last_touchpoint_at,
             last_touchpoint_type: bc.last_touchpoint_type,
             preferred_contact_channel: bc.preferred_contact_channel,
             next_touchpoint_at: bc.next_touchpoint_at,
             is_vip: bc.is_vip,
             is_trending: bc.is_trending,
             l30d_rank: bc.l30d_rank,
             l90d_rank: bc.l90d_rank,
             l30d_gmv_cents: bc.l30d_gmv_cents,
             stability_score: bc.stability_score,
             engagement_priority: bc.engagement_priority,
             vip_locked: bc.vip_locked
           }}
      )
      |> Repo.all()
      |> Map.new()
    end
  end

  @spec update_brand_creator_engagement(pos_integer(), pos_integer(), map()) ::
          {:ok, BrandCreator.t()} | {:error, Ecto.Changeset.t()}
  def update_brand_creator_engagement(brand_id, creator_id, attrs) do
    brand_creator = get_or_create_brand_creator!(brand_id, creator_id)

    brand_creator
    |> BrandCreator.changeset(normalize_engagement_attrs(attrs))
    |> Repo.update()
  end

  @spec record_outreach_touchpoint(
          pos_integer(),
          pos_integer(),
          BrandCreator.last_touchpoint_type(),
          DateTime.t()
        ) :: {:ok, BrandCreator.t()} | {:error, Ecto.Changeset.t()}
  def record_outreach_touchpoint(brand_id, creator_id, touchpoint_type, %DateTime{} = touched_at)
      when touchpoint_type in [:email, :sms] do
    brand_creator = get_or_create_brand_creator!(brand_id, creator_id)

    should_update? =
      is_nil(brand_creator.last_touchpoint_at) or
        DateTime.compare(touched_at, brand_creator.last_touchpoint_at) == :gt

    if should_update? do
      update_brand_creator(brand_creator, %{
        last_touchpoint_at: touched_at,
        last_touchpoint_type: touchpoint_type
      })
    else
      {:ok, brand_creator}
    end
  end

  @spec normalize_engagement_attrs(map()) :: map()
  def normalize_engagement_attrs(attrs) when is_map(attrs) do
    Enum.reduce(attrs, %{}, fn
      {"last_touchpoint_at", value}, acc ->
        put_engagement_datetime_value(acc, :last_touchpoint_at, value)

      {"last_touchpoint_type", value}, acc ->
        put_engagement_value(acc, :last_touchpoint_type, value)

      {"preferred_contact_channel", value}, acc ->
        put_engagement_value(acc, :preferred_contact_channel, value)

      {"next_touchpoint_at", value}, acc ->
        put_engagement_datetime_value(acc, :next_touchpoint_at, value)

      {:last_touchpoint_at, value}, acc ->
        put_engagement_datetime_value(acc, :last_touchpoint_at, value)

      {:last_touchpoint_type, value}, acc ->
        put_engagement_value(acc, :last_touchpoint_type, value)

      {:preferred_contact_channel, value}, acc ->
        put_engagement_value(acc, :preferred_contact_channel, value)

      {:next_touchpoint_at, value}, acc ->
        put_engagement_datetime_value(acc, :next_touchpoint_at, value)

      _, acc ->
        acc
    end)
  end

  defp put_engagement_value(acc, key, ""), do: Map.put(acc, key, nil)
  defp put_engagement_value(acc, key, value), do: Map.put(acc, key, value)

  defp put_engagement_datetime_value(acc, key, ""), do: Map.put(acc, key, nil)
  defp put_engagement_datetime_value(acc, key, nil), do: Map.put(acc, key, nil)

  defp put_engagement_datetime_value(acc, key, %DateTime{} = value),
    do: Map.put(acc, key, DateTime.truncate(value, :second))

  defp put_engagement_datetime_value(acc, key, %NaiveDateTime{} = value) do
    value
    |> NaiveDateTime.truncate(:second)
    |> DateTime.from_naive!("Etc/UTC")
    |> then(&Map.put(acc, key, &1))
  end

  defp put_engagement_datetime_value(acc, key, %Date{} = value) do
    value
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> then(&Map.put(acc, key, &1))
  end

  defp put_engagement_datetime_value(acc, key, value) when is_binary(value) do
    case parse_engagement_date_value(value) do
      {:ok, parsed} -> Map.put(acc, key, parsed)
      :error -> Map.put(acc, key, value)
    end
  end

  defp put_engagement_datetime_value(acc, key, value), do: Map.put(acc, key, value)

  defp parse_engagement_date_value(""), do: {:ok, nil}

  defp parse_engagement_date_value(value) when is_binary(value) do
    parsed =
      parse_engagement_iso_datetime(value) ||
        parse_naive_date_time(value) ||
        parse_engagement_date_only(value)

    case parsed do
      nil -> :error
      datetime -> {:ok, datetime}
    end
  end

  defp parse_engagement_iso_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      {:error, _} -> nil
    end
  end

  defp parse_naive_date_time(value) do
    normalized =
      case String.length(value) do
        16 -> value <> ":00"
        _ -> value
      end

    with {:ok, naive} <- NaiveDateTime.from_iso8601(normalized),
         {:ok, datetime} <- DateTime.from_naive(naive, "Etc/UTC") do
      DateTime.truncate(datetime, :second)
    else
      _ -> nil
    end
  end

  defp parse_engagement_date_only(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
      {:error, _} -> nil
    end
  end

  defp get_or_create_brand_creator!(brand_id, creator_id) do
    case get_brand_creator(brand_id, creator_id) do
      nil ->
        case add_creator_to_brand(creator_id, brand_id) do
          {:ok, %BrandCreator{} = created} ->
            created

          {:error, _} ->
            Repo.get_by!(BrandCreator, brand_id: brand_id, creator_id: creator_id)
        end

      %BrandCreator{} = brand_creator ->
        brand_creator
    end
  end

  ## Creator Samples

  @spec create_creator_sample(map()) ::
          {:ok, CreatorSample.t()} | {:error, Ecto.Changeset.t() | term()}
  @doc """
  Creates a creator sample.
  Also increments the sample_count on the linked product (if any) atomically.
  """
  def create_creator_sample(attrs \\ %{}) do
    changeset = CreatorSample.changeset(%CreatorSample{}, attrs)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:sample, changeset)
    |> Ecto.Multi.run(:increment_count, fn _repo, %{sample: sample} ->
      if sample.product_id do
        SocialObjects.Catalog.increment_product_sample_count(sample.product_id)
      end

      {:ok, :incremented}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{sample: sample}} -> {:ok, sample}
      {:error, :sample, changeset, _} -> {:error, changeset}
      {:error, _, reason, _} -> {:error, reason}
    end
  end

  @spec list_samples_for_creator(pos_integer()) :: [CreatorSample.t()]
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

  @spec list_samples_for_creator(pos_integer(), pos_integer()) :: [CreatorSample.t()]
  def list_samples_for_creator(brand_id, creator_id) do
    from(cs in CreatorSample,
      where: cs.brand_id == ^brand_id and cs.creator_id == ^creator_id,
      order_by: [desc: cs.ordered_at],
      preload: [:brand, :product]
    )
    |> Repo.all()
  end

  @spec count_samples_for_creator(pos_integer()) :: non_neg_integer()
  @doc """
  Gets sample count for a creator.
  """
  def count_samples_for_creator(creator_id) do
    from(cs in CreatorSample, where: cs.creator_id == ^creator_id)
    |> Repo.aggregate(:count)
  end

  @spec count_samples_for_creator(pos_integer(), pos_integer()) :: non_neg_integer()
  def count_samples_for_creator(brand_id, creator_id) do
    from(cs in CreatorSample, where: cs.brand_id == ^brand_id and cs.creator_id == ^creator_id)
    |> Repo.aggregate(:count)
  end

  @spec count_sampled_creators() :: non_neg_integer()
  @doc """
  Counts unique creators who have received at least one sample.
  """
  def count_sampled_creators do
    from(cs in CreatorSample, select: count(cs.creator_id, :distinct))
    |> Repo.one()
  end

  @spec count_sampled_creators(pos_integer()) :: non_neg_integer()
  def count_sampled_creators(brand_id) do
    from(cs in CreatorSample,
      where: cs.brand_id == ^brand_id,
      select: count(cs.creator_id, :distinct)
    )
    |> Repo.one()
  end

  @spec batch_count_samples([pos_integer()]) :: %{optional(pos_integer()) => non_neg_integer()}
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

  @spec batch_count_samples(pos_integer(), [pos_integer()]) :: %{
          optional(pos_integer()) => non_neg_integer()
        }
  def batch_count_samples(brand_id, creator_ids) when is_list(creator_ids) do
    if creator_ids == [] do
      %{}
    else
      from(cs in CreatorSample,
        where: cs.brand_id == ^brand_id and cs.creator_id in ^creator_ids,
        group_by: cs.creator_id,
        select: {cs.creator_id, count(cs.id)}
      )
      |> Repo.all()
      |> Map.new()
    end
  end

  @spec batch_get_last_sample_at([pos_integer()]) :: %{optional(pos_integer()) => DateTime.t()}
  @doc """
  Batch gets last sample date for multiple creators.
  Returns a map of creator_id => last_sample_at (DateTime or nil).
  """
  def batch_get_last_sample_at(creator_ids) when is_list(creator_ids) do
    if creator_ids == [] do
      %{}
    else
      from(cs in CreatorSample,
        where: cs.creator_id in ^creator_ids,
        group_by: cs.creator_id,
        select: {cs.creator_id, max(cs.ordered_at)}
      )
      |> Repo.all()
      |> Map.new()
    end
  end

  @spec batch_get_last_sample_at(pos_integer(), [pos_integer()]) :: %{
          optional(pos_integer()) => DateTime.t()
        }
  def batch_get_last_sample_at(brand_id, creator_ids) when is_list(creator_ids) do
    if creator_ids == [] do
      %{}
    else
      from(cs in CreatorSample,
        where: cs.brand_id == ^brand_id and cs.creator_id in ^creator_ids,
        group_by: cs.creator_id,
        select: {cs.creator_id, max(cs.ordered_at)}
      )
      |> Repo.all()
      |> Map.new()
    end
  end

  ## Creator Videos

  @spec create_creator_video(pos_integer(), map()) ::
          {:ok, CreatorVideo.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Creates a creator video.
  """
  def create_creator_video(brand_id, attrs \\ %{}) do
    %CreatorVideo{brand_id: brand_id}
    |> CreatorVideo.changeset(attrs)
    |> Repo.insert()
  end

  @spec get_video_by_tiktok_id(String.t()) :: CreatorVideo.t() | nil
  @doc """
  Gets a video by TikTok video ID.
  """
  def get_video_by_tiktok_id(tiktok_video_id) do
    Repo.get_by(CreatorVideo, tiktok_video_id: tiktok_video_id)
  end

  @spec list_videos_for_creator(pos_integer(), pos_integer()) :: [CreatorVideo.t()]
  @doc """
  Lists videos for a creator.
  """
  def list_videos_for_creator(brand_id, creator_id) do
    from(cv in CreatorVideo,
      where: cv.brand_id == ^brand_id and cv.creator_id == ^creator_id,
      order_by: [desc: cv.posted_at]
    )
    |> Repo.all()
  end

  @spec count_videos_for_brand(pos_integer()) :: non_neg_integer()
  @doc """
  Returns the count of videos associated with a brand.
  """
  def count_videos_for_brand(brand_id) do
    from(cv in CreatorVideo, where: cv.brand_id == ^brand_id)
    |> Repo.aggregate(:count)
  end

  @spec batch_sum_commission(pos_integer(), [pos_integer()]) :: %{
          optional(pos_integer()) => non_neg_integer()
        }
  @doc """
  Batch sums commission earned (est_commission_cents) for multiple creators.
  Returns a map of creator_id => total_commission_cents.
  """
  def batch_sum_commission(brand_id, creator_ids) when is_list(creator_ids) do
    if creator_ids == [] do
      %{}
    else
      from(cv in CreatorVideo,
        where: cv.brand_id == ^brand_id and cv.creator_id in ^creator_ids,
        group_by: cv.creator_id,
        select: {cv.creator_id, coalesce(sum(cv.est_commission_cents), 0)}
      )
      |> Repo.all()
      |> Map.new()
    end
  end

  @spec update_creator_video(CreatorVideo.t(), map()) ::
          {:ok, CreatorVideo.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Updates an existing creator video record.
  """
  def update_creator_video(%CreatorVideo{} = video, attrs) do
    video
    |> CreatorVideo.changeset(attrs)
    |> Repo.update()
  end

  @spec upsert_video_by_tiktok_id(pos_integer(), String.t(), map()) ::
          {:ok, CreatorVideo.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Upserts a video by TikTok video ID.

  The metrics on `creator_videos` are treated as best-known all-time values.
  Monotonic metrics (GMV, views, items sold, orders, etc.) only move upward.
  Non-monotonic fields (like CTR/GPM) update only when incoming GMV is at least
  as strong as the existing all-time GMV, preventing low-quality rows from
  clobbering stronger historical values.

  Returns `{:ok, video}` or `{:error, changeset}`.
  """
  def upsert_video_by_tiktok_id(brand_id, tiktok_video_id, attrs) do
    attrs_with_id = Map.put(attrs, :tiktok_video_id, tiktok_video_id)
    conflict_query = creator_video_upsert_conflict_query()

    %CreatorVideo{brand_id: brand_id}
    |> CreatorVideo.changeset(attrs_with_id)
    |> Repo.insert(
      on_conflict: conflict_query,
      conflict_target: :tiktok_video_id,
      returning: true
    )
  end

  @spec list_video_metric_snapshots_by_keys(pos_integer(), Date.t(), pos_integer(), [String.t()]) ::
          %{optional(String.t()) => map()}
  @doc """
  Loads existing metric snapshots for a specific `{date, window}` keyed by TikTok video id.
  """
  def list_video_metric_snapshots_by_keys(
        _brand_id,
        _snapshot_date,
        _window_days,
        []
      ) do
    %{}
  end

  def list_video_metric_snapshots_by_keys(brand_id, snapshot_date, window_days, tiktok_video_ids)
      when is_list(tiktok_video_ids) do
    from(s in CreatorVideoMetricSnapshot,
      where: s.brand_id == ^brand_id,
      where: s.snapshot_date == ^snapshot_date,
      where: s.window_days == ^window_days,
      where: s.tiktok_video_id in ^tiktok_video_ids,
      select: %{
        creator_video_id: s.creator_video_id,
        tiktok_video_id: s.tiktok_video_id,
        gmv_cents: s.gmv_cents,
        views: s.views,
        items_sold: s.items_sold,
        gpm_cents: s.gpm_cents,
        ctr: s.ctr
      }
    )
    |> Repo.all()
    |> Map.new(fn snapshot -> {snapshot.tiktok_video_id, snapshot} end)
  end

  @spec upsert_video_metric_snapshots([map()]) :: {non_neg_integer(), nil | [term()]}
  @doc """
  Bulk upserts video metric snapshots.

  For same-day conflicts, keeps the stronger metric row (highest GMV, with
  monotonic safeguards for cumulative metrics).
  """
  def upsert_video_metric_snapshots([]), do: {0, nil}

  def upsert_video_metric_snapshots(rows) when is_list(rows) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    conflict_query = creator_video_snapshot_upsert_conflict_query()

    rows =
      Enum.map(rows, fn row ->
        row
        |> Map.put(:updated_at, now)
        |> Map.put_new(:inserted_at, now)
      end)

    Repo.insert_all(CreatorVideoMetricSnapshot, rows,
      on_conflict: conflict_query,
      conflict_target: [:brand_id, :tiktok_video_id, :snapshot_date, :window_days]
    )
  end

  defp creator_video_upsert_conflict_query do
    from(v in CreatorVideo,
      update: [
        set: [
          title:
            fragment(
              """
              CASE
                WHEN COALESCE(EXCLUDED.gmv_cents, 0) >= COALESCE(?, 0)
                THEN EXCLUDED.title
                ELSE ?
              END
              """,
              v.gmv_cents,
              v.title
            ),
          video_url:
            fragment(
              """
              CASE
                WHEN COALESCE(EXCLUDED.gmv_cents, 0) >= COALESCE(?, 0)
                THEN EXCLUDED.video_url
                ELSE ?
              END
              """,
              v.gmv_cents,
              v.video_url
            ),
          posted_at: fragment("COALESCE(?, EXCLUDED.posted_at)", v.posted_at),
          gmv_cents:
            fragment(
              "GREATEST(COALESCE(?, 0), COALESCE(EXCLUDED.gmv_cents, 0))",
              v.gmv_cents
            ),
          items_sold:
            fragment(
              "GREATEST(COALESCE(?, 0), COALESCE(EXCLUDED.items_sold, 0))",
              v.items_sold
            ),
          affiliate_orders:
            fragment(
              "GREATEST(COALESCE(?, 0), COALESCE(EXCLUDED.affiliate_orders, 0))",
              v.affiliate_orders
            ),
          impressions:
            fragment(
              "GREATEST(COALESCE(?, 0), COALESCE(EXCLUDED.impressions, 0))",
              v.impressions
            ),
          likes: fragment("GREATEST(COALESCE(?, 0), COALESCE(EXCLUDED.likes, 0))", v.likes),
          comments:
            fragment(
              "GREATEST(COALESCE(?, 0), COALESCE(EXCLUDED.comments, 0))",
              v.comments
            ),
          shares: fragment("GREATEST(COALESCE(?, 0), COALESCE(EXCLUDED.shares, 0))", v.shares),
          ctr:
            fragment(
              """
              CASE
                WHEN COALESCE(EXCLUDED.gmv_cents, 0) >= COALESCE(?, 0)
                THEN EXCLUDED.ctr
                ELSE ?
              END
              """,
              v.gmv_cents,
              v.ctr
            ),
          est_commission_cents:
            fragment(
              """
              GREATEST(
                COALESCE(?, 0),
                COALESCE(EXCLUDED.est_commission_cents, 0)
              )
              """,
              v.est_commission_cents
            ),
          gpm_cents:
            fragment(
              """
              CASE
                WHEN COALESCE(EXCLUDED.gmv_cents, 0) >= COALESCE(?, 0)
                THEN EXCLUDED.gpm_cents
                ELSE ?
              END
              """,
              v.gmv_cents,
              v.gpm_cents
            ),
          duration:
            fragment(
              """
              CASE
                WHEN COALESCE(EXCLUDED.gmv_cents, 0) >= COALESCE(?, 0)
                THEN EXCLUDED.duration
                ELSE ?
              END
              """,
              v.gmv_cents,
              v.duration
            ),
          hash_tags:
            fragment(
              """
              CASE
                WHEN COALESCE(EXCLUDED.gmv_cents, 0) >= COALESCE(?, 0)
                THEN EXCLUDED.hash_tags
                ELSE ?
              END
              """,
              v.gmv_cents,
              v.hash_tags
            ),
          updated_at: fragment("NOW()")
        ]
      ]
    )
  end

  defp creator_video_snapshot_upsert_conflict_query do
    from(s in CreatorVideoMetricSnapshot,
      update: [
        set: [
          creator_video_id:
            fragment("COALESCE(EXCLUDED.creator_video_id, ?)", s.creator_video_id),
          gmv_cents:
            fragment(
              """
              GREATEST(
                COALESCE(?, 0),
                COALESCE(EXCLUDED.gmv_cents, 0)
              )
              """,
              s.gmv_cents
            ),
          views:
            fragment(
              """
              GREATEST(
                COALESCE(?, 0),
                COALESCE(EXCLUDED.views, 0)
              )
              """,
              s.views
            ),
          items_sold:
            fragment(
              """
              GREATEST(
                COALESCE(?, 0),
                COALESCE(EXCLUDED.items_sold, 0)
              )
              """,
              s.items_sold
            ),
          gpm_cents:
            fragment(
              """
              CASE
                WHEN COALESCE(EXCLUDED.gmv_cents, 0) >=
                     COALESCE(?, 0)
                THEN EXCLUDED.gpm_cents
                ELSE ?
              END
              """,
              s.gmv_cents,
              s.gpm_cents
            ),
          ctr:
            fragment(
              """
              CASE
                WHEN COALESCE(EXCLUDED.gmv_cents, 0) >=
                     COALESCE(?, 0)
                THEN EXCLUDED.ctr
                ELSE ?
              END
              """,
              s.gmv_cents,
              s.ctr
            ),
          source_run_id: fragment("COALESCE(EXCLUDED.source_run_id, ?)", s.source_run_id),
          raw_payload:
            fragment(
              """
              CASE
                WHEN COALESCE(EXCLUDED.gmv_cents, 0) >=
                     COALESCE(?, 0)
                THEN EXCLUDED.raw_payload
                ELSE ?
              END
              """,
              s.gmv_cents,
              s.raw_payload
            ),
          updated_at: fragment("NOW()")
        ]
      ]
    )
  end

  @spec update_video_thumbnail(CreatorVideo.t(), String.t(), String.t() | nil) ::
          {:ok, CreatorVideo.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Updates a video's thumbnail URL and optionally its storage key.
  """
  def update_video_thumbnail(%CreatorVideo{} = video, thumbnail_url, storage_key \\ nil) do
    video
    |> Ecto.Changeset.change(%{
      thumbnail_url: thumbnail_url,
      thumbnail_storage_key: storage_key
    })
    |> Repo.update()
  end

  @spec list_videos_without_thumbnails(pos_integer(), pos_integer()) :: [CreatorVideo.t()]
  @doc """
  Lists videos that don't have thumbnails yet.
  Used by VideoSyncWorker to fetch missing thumbnails.
  """
  def list_videos_without_thumbnails(brand_id, limit \\ 50) do
    from(v in CreatorVideo,
      where: v.brand_id == ^brand_id,
      where: is_nil(v.thumbnail_url),
      where: not is_nil(v.video_url),
      order_by: [desc: v.gmv_cents],
      limit: ^limit
    )
    |> Repo.all()
  end

  @spec list_videos_needing_thumbnail_storage(pos_integer(), pos_integer()) :: [CreatorVideo.t()]
  @doc """
  Lists videos that have thumbnails but haven't been stored in storage yet.
  Used by ThumbnailBackfillWorker to migrate existing thumbnails to storage.
  """
  def list_videos_needing_thumbnail_storage(brand_id, limit \\ 50) do
    from(v in CreatorVideo,
      where: v.brand_id == ^brand_id,
      where: not is_nil(v.thumbnail_url),
      where: not is_nil(v.video_url),
      where: is_nil(v.thumbnail_storage_key),
      order_by: [desc: v.gmv_cents],
      limit: ^limit
    )
    |> Repo.all()
  end

  @spec batch_get_last_video_at(pos_integer(), [pos_integer()]) :: %{
          optional(pos_integer()) => DateTime.t()
        }
  @doc """
  Batch gets last video posted_at for multiple creators.
  Returns a map of creator_id => last_video_at (DateTime or nil).
  """
  def batch_get_last_video_at(brand_id, creator_ids) when is_list(creator_ids) do
    if creator_ids == [] do
      %{}
    else
      from(cv in CreatorVideo,
        where: cv.brand_id == ^brand_id and cv.creator_id in ^creator_ids,
        group_by: cv.creator_id,
        select: {cv.creator_id, max(cv.posted_at)}
      )
      |> Repo.all()
      |> Map.new()
    end
  end

  @spec search_videos_paginated(keyword()) :: %{
          videos: [map()],
          total: non_neg_integer(),
          page: pos_integer(),
          per_page: pos_integer(),
          has_more: boolean()
        }
  @doc """
  Searches and paginates videos with optional filters.

  ## Options
    - brand_id: Filter by brand (required)
    - period: "all", "30", or "90" (default: "all")
    - search_query: Search by title, creator username, or hashtags
    - creator_id: Filter by specific creator
    - min_gmv: Minimum GMV in cents (applies to selected metric source)
    - posted_after: Filter videos posted after date
    - posted_before: Filter videos posted before date
    - hashtags: List of hashtags to filter by
    - sort_by: Column to sort (gmv, gpm, views, ctr, items_sold, posted_at)
    - sort_dir: "asc" or "desc" (default: "desc")
    - page: Page number (default: 1)
    - per_page: Items per page (default: 24)

  ## Returns
    A map with videos, total, page, per_page, has_more
  """
  def search_videos_paginated(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 24)
    sort_by = Keyword.get(opts, :sort_by, "gmv")
    sort_dir = Keyword.get(opts, :sort_dir, "desc")
    brand_id = Keyword.get(opts, :brand_id)
    metric_period = normalize_video_metric_period(Keyword.get(opts, :period, "all"))

    {base_query, metric_source} = build_video_search_query(brand_id, metric_period)

    query =
      base_query
      |> apply_video_search_filter(Keyword.get(opts, :search_query, ""))
      |> apply_video_min_gmv_filter(Keyword.get(opts, :min_gmv), metric_source)
      |> apply_video_creator_filter(Keyword.get(opts, :creator_id))
      |> apply_video_date_filter(
        Keyword.get(opts, :posted_after),
        Keyword.get(opts, :posted_before)
      )
      |> apply_video_hashtag_filter(Keyword.get(opts, :hashtags))

    # Only compute expensive count for non-search queries (initial load)
    # For search, use LIMIT+1 trick to determine has_more without counting all rows
    search_query = Keyword.get(opts, :search_query, "")
    skip_count = search_query != "" and search_query != nil

    # Fetch one extra row to determine if there are more results
    videos =
      query
      |> apply_video_sort(sort_by, sort_dir, metric_source)
      |> limit(^(per_page + 1))
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    has_more = length(videos) > per_page
    videos = Enum.take(videos, per_page)

    total =
      if skip_count do
        # For search queries, estimate based on current page
        # This avoids the expensive COUNT query during typing
        if has_more do
          # We know there are at least this many
          page * per_page + 1
        else
          (page - 1) * per_page + length(videos)
        end
      else
        query
        |> exclude(:select)
        |> exclude(:order_by)
        |> Repo.aggregate(:count)
      end

    %{
      videos: videos,
      total: total,
      page: page,
      per_page: per_page,
      has_more: has_more
    }
  end

  @spec list_creators_with_videos(pos_integer()) :: [
          %{id: pos_integer(), tiktok_username: String.t()}
        ]
  @doc """
  Lists creators who have at least one video for a brand.
  Returns list of maps with id and tiktok_username.
  """
  def list_creators_with_videos(brand_id) do
    from(c in Creator,
      join: v in CreatorVideo,
      on: v.creator_id == c.id and v.brand_id == ^brand_id,
      distinct: true,
      select: %{id: c.id, tiktok_username: c.tiktok_username},
      order_by: [asc: c.tiktok_username]
    )
    |> Repo.all()
  end

  # Video search filter helpers
  defp normalize_video_metric_period("30"), do: {:snapshot, 30}
  defp normalize_video_metric_period("90"), do: {:snapshot, 90}
  defp normalize_video_metric_period("all"), do: :all_time
  defp normalize_video_metric_period(_), do: :all_time

  defp build_video_search_query(brand_id, :all_time) do
    query =
      from(v in CreatorVideo,
        as: :video,
        where: v.brand_id == ^brand_id,
        join: c in assoc(v, :creator),
        as: :creator,
        select: %{
          id: v.id,
          thumbnail_url: v.thumbnail_url,
          thumbnail_storage_key: v.thumbnail_storage_key,
          duration: v.duration,
          title: v.title,
          gmv_cents: v.gmv_cents,
          gpm_cents: v.gpm_cents,
          impressions: v.impressions,
          ctr: v.ctr,
          posted_at: v.posted_at,
          items_sold: v.items_sold,
          tiktok_video_id: v.tiktok_video_id,
          video_url: v.video_url,
          creator: %{
            id: c.id,
            tiktok_username: c.tiktok_username,
            tiktok_avatar_url: c.tiktok_avatar_url,
            tiktok_avatar_storage_key: c.tiktok_avatar_storage_key,
            tiktok_nickname: c.tiktok_nickname
          }
        }
      )

    {query, :all_time}
  end

  defp build_video_search_query(brand_id, {:snapshot, window_days}) do
    latest_snapshot_query = latest_video_metric_snapshots_query(brand_id, window_days)

    query =
      from(v in CreatorVideo,
        as: :video,
        where: v.brand_id == ^brand_id,
        join: c in assoc(v, :creator),
        as: :creator,
        left_join: s in subquery(latest_snapshot_query),
        as: :snapshot,
        on: s.tiktok_video_id == v.tiktok_video_id,
        select: %{
          id: v.id,
          thumbnail_url: v.thumbnail_url,
          thumbnail_storage_key: v.thumbnail_storage_key,
          duration: v.duration,
          title: v.title,
          gmv_cents: coalesce(s.gmv_cents, 0),
          gpm_cents: s.gpm_cents,
          impressions: coalesce(s.views, 0),
          ctr: s.ctr,
          posted_at: v.posted_at,
          items_sold: coalesce(s.items_sold, 0),
          tiktok_video_id: v.tiktok_video_id,
          video_url: v.video_url,
          creator: %{
            id: c.id,
            tiktok_username: c.tiktok_username,
            tiktok_avatar_url: c.tiktok_avatar_url,
            tiktok_avatar_storage_key: c.tiktok_avatar_storage_key,
            tiktok_nickname: c.tiktok_nickname
          }
        }
      )

    {query, :snapshot}
  end

  defp latest_video_metric_snapshots_query(brand_id, window_days) do
    from(s in CreatorVideoMetricSnapshot,
      where: s.brand_id == ^brand_id and s.window_days == ^window_days,
      distinct: s.tiktok_video_id,
      order_by: [asc: s.tiktok_video_id, desc: s.snapshot_date, desc: s.id],
      select: %{
        tiktok_video_id: s.tiktok_video_id,
        gmv_cents: s.gmv_cents,
        gpm_cents: s.gpm_cents,
        views: s.views,
        ctr: s.ctr,
        items_sold: s.items_sold
      }
    )
  end

  defp apply_video_search_filter(query, ""), do: query
  defp apply_video_search_filter(query, nil), do: query

  defp apply_video_search_filter(query, search_query) do
    pattern = "%#{search_query}%"

    from([video: v, creator: c] in query,
      where:
        ilike(v.title, ^pattern) or
          ilike(c.tiktok_username, ^pattern) or
          fragment(
            "EXISTS (SELECT 1 FROM unnest(?) AS tag WHERE tag ILIKE ?)",
            v.hash_tags,
            ^pattern
          )
    )
  end

  defp apply_video_min_gmv_filter(query, nil, _metric_source), do: query
  defp apply_video_min_gmv_filter(query, 0, _metric_source), do: query

  defp apply_video_min_gmv_filter(query, min_gmv, :all_time) when is_integer(min_gmv) do
    where(query, [video: v], v.gmv_cents >= ^min_gmv)
  end

  defp apply_video_min_gmv_filter(query, min_gmv, :snapshot) when is_integer(min_gmv) do
    where(query, [snapshot: s], coalesce(s.gmv_cents, 0) >= ^min_gmv)
  end

  defp apply_video_creator_filter(query, nil), do: query

  defp apply_video_creator_filter(query, creator_id) do
    where(query, [video: v], v.creator_id == ^creator_id)
  end

  defp apply_video_date_filter(query, nil, nil), do: query

  defp apply_video_date_filter(query, posted_after, posted_before) do
    query
    |> maybe_apply_posted_after(posted_after)
    |> maybe_apply_posted_before(posted_before)
  end

  defp maybe_apply_posted_after(query, nil), do: query
  defp maybe_apply_posted_after(query, date), do: where(query, [video: v], v.posted_at >= ^date)

  defp maybe_apply_posted_before(query, nil), do: query
  defp maybe_apply_posted_before(query, date), do: where(query, [video: v], v.posted_at <= ^date)

  defp apply_video_hashtag_filter(query, nil), do: query
  defp apply_video_hashtag_filter(query, []), do: query

  defp apply_video_hashtag_filter(query, hashtags) when is_list(hashtags) do
    where(query, [video: v], fragment("? && ?", v.hash_tags, ^hashtags))
  end

  defp apply_video_sort(query, "gmv", "desc", :all_time),
    do: order_by(query, [video: v], desc_nulls_last: v.gmv_cents)

  defp apply_video_sort(query, "gmv", "asc", :all_time),
    do: order_by(query, [video: v], asc_nulls_last: v.gmv_cents)

  defp apply_video_sort(query, "gpm", "desc", :all_time),
    do: order_by(query, [video: v], desc_nulls_last: v.gpm_cents)

  defp apply_video_sort(query, "gpm", "asc", :all_time),
    do: order_by(query, [video: v], asc_nulls_last: v.gpm_cents)

  defp apply_video_sort(query, "views", "desc", :all_time),
    do: order_by(query, [video: v], desc_nulls_last: v.impressions)

  defp apply_video_sort(query, "views", "asc", :all_time),
    do: order_by(query, [video: v], asc_nulls_last: v.impressions)

  defp apply_video_sort(query, "ctr", "desc", :all_time),
    do: order_by(query, [video: v], desc_nulls_last: v.ctr)

  defp apply_video_sort(query, "ctr", "asc", :all_time),
    do: order_by(query, [video: v], asc_nulls_last: v.ctr)

  defp apply_video_sort(query, "items_sold", "desc", :all_time),
    do: order_by(query, [video: v], desc_nulls_last: v.items_sold)

  defp apply_video_sort(query, "items_sold", "asc", :all_time),
    do: order_by(query, [video: v], asc_nulls_last: v.items_sold)

  defp apply_video_sort(query, "gmv", "desc", :snapshot),
    do: order_by(query, [snapshot: s], desc_nulls_last: s.gmv_cents)

  defp apply_video_sort(query, "gmv", "asc", :snapshot),
    do: order_by(query, [snapshot: s], asc_nulls_last: s.gmv_cents)

  defp apply_video_sort(query, "gpm", "desc", :snapshot),
    do: order_by(query, [snapshot: s], desc_nulls_last: s.gpm_cents)

  defp apply_video_sort(query, "gpm", "asc", :snapshot),
    do: order_by(query, [snapshot: s], asc_nulls_last: s.gpm_cents)

  defp apply_video_sort(query, "views", "desc", :snapshot),
    do: order_by(query, [snapshot: s], desc_nulls_last: s.views)

  defp apply_video_sort(query, "views", "asc", :snapshot),
    do: order_by(query, [snapshot: s], asc_nulls_last: s.views)

  defp apply_video_sort(query, "ctr", "desc", :snapshot),
    do: order_by(query, [snapshot: s], desc_nulls_last: s.ctr)

  defp apply_video_sort(query, "ctr", "asc", :snapshot),
    do: order_by(query, [snapshot: s], asc_nulls_last: s.ctr)

  defp apply_video_sort(query, "items_sold", "desc", :snapshot),
    do: order_by(query, [snapshot: s], desc_nulls_last: s.items_sold)

  defp apply_video_sort(query, "items_sold", "asc", :snapshot),
    do: order_by(query, [snapshot: s], asc_nulls_last: s.items_sold)

  defp apply_video_sort(query, "posted_at", "desc", _metric_source),
    do: order_by(query, [video: v], desc_nulls_last: v.posted_at)

  defp apply_video_sort(query, "posted_at", "asc", _metric_source),
    do: order_by(query, [video: v], asc_nulls_last: v.posted_at)

  defp apply_video_sort(query, _, _, :all_time),
    do: order_by(query, [video: v], desc_nulls_last: v.gmv_cents)

  defp apply_video_sort(query, _, _, :snapshot),
    do: order_by(query, [snapshot: s], desc_nulls_last: s.gmv_cents)

  @spec batch_load_snapshot_deltas([pos_integer()], pos_integer()) :: %{
          optional(pos_integer()) => %{
            gmv_delta: integer() | nil,
            follower_delta: integer() | nil,
            start_date: Date.t() | nil,
            end_date: Date.t() | nil,
            has_complete_data: boolean()
          }
        }
  @doc """
  Batch loads snapshot deltas for multiple creators over a date range.

  Returns a map of creator_id => %{
    gmv_delta: integer | nil,
    follower_delta: integer | nil,
    start_date: Date | nil,
    end_date: Date | nil,
    has_complete_data: boolean
  }
  """
  def batch_load_snapshot_deltas([], _days_back), do: %{}

  def batch_load_snapshot_deltas(creator_ids, days_back) when is_list(creator_ids) do
    end_date = Date.utc_today()
    start_date = Date.add(end_date, -days_back)

    # Query all snapshots in the date range for these creators
    snapshots =
      from(s in CreatorPerformanceSnapshot,
        where: s.creator_id in ^creator_ids,
        where: s.snapshot_date >= ^start_date and s.snapshot_date <= ^end_date,
        where: s.source == "tiktok_marketplace",
        select: %{
          creator_id: s.creator_id,
          snapshot_date: s.snapshot_date,
          gmv_cents: s.gmv_cents,
          follower_count: s.follower_count
        },
        order_by: [asc: s.creator_id, asc: s.snapshot_date]
      )
      |> Repo.all()

    # Group by creator_id and compute deltas
    snapshots
    |> Enum.group_by(& &1.creator_id)
    |> Enum.map(fn {creator_id, creator_snapshots} ->
      compute_snapshot_delta(creator_id, creator_snapshots, start_date, end_date)
    end)
    |> Map.new()
  end

  @spec batch_load_snapshot_deltas(pos_integer(), [pos_integer()], pos_integer()) :: %{
          optional(pos_integer()) => %{
            gmv_delta: integer() | nil,
            follower_delta: integer() | nil,
            start_date: Date.t() | nil,
            end_date: Date.t() | nil,
            has_complete_data: boolean()
          }
        }
  def batch_load_snapshot_deltas(brand_id, creator_ids, days_back) when is_list(creator_ids) do
    end_date = Date.utc_today()
    start_date = Date.add(end_date, -days_back)

    snapshots =
      from(s in CreatorPerformanceSnapshot,
        where: s.brand_id == ^brand_id and s.creator_id in ^creator_ids,
        where: s.snapshot_date >= ^start_date and s.snapshot_date <= ^end_date,
        where: s.source == "tiktok_marketplace",
        select: %{
          creator_id: s.creator_id,
          snapshot_date: s.snapshot_date,
          gmv_cents: s.gmv_cents,
          follower_count: s.follower_count
        },
        order_by: [asc: s.creator_id, asc: s.snapshot_date]
      )
      |> Repo.all()

    snapshots
    |> Enum.group_by(& &1.creator_id)
    |> Enum.map(fn {creator_id, creator_snapshots} ->
      compute_snapshot_delta(creator_id, creator_snapshots, start_date, end_date)
    end)
    |> Map.new()
  end

  defp compute_snapshot_delta(creator_id, [], _requested_start, _requested_end) do
    {creator_id,
     %{
       gmv_delta: nil,
       follower_delta: nil,
       start_date: nil,
       end_date: nil,
       has_complete_data: false
     }}
  end

  defp compute_snapshot_delta(creator_id, [single], _requested_start, _requested_end) do
    # Only one snapshot - can show where data starts but no delta
    {creator_id,
     %{
       gmv_delta: nil,
       follower_delta: nil,
       start_date: single.snapshot_date,
       end_date: single.snapshot_date,
       has_complete_data: false
     }}
  end

  defp compute_snapshot_delta(creator_id, snapshots, requested_start, requested_end) do
    first = List.first(snapshots)
    last = List.last(snapshots)

    # Check if we have data at both requested boundaries
    has_complete = first.snapshot_date == requested_start and last.snapshot_date == requested_end

    {creator_id,
     %{
       gmv_delta: safe_subtract(last.gmv_cents, first.gmv_cents),
       follower_delta: safe_subtract(last.follower_count, first.follower_count),
       start_date: first.snapshot_date,
       end_date: last.snapshot_date,
       has_complete_data: has_complete
     }}
  end

  defp safe_subtract(nil, _), do: nil
  defp safe_subtract(_, nil), do: nil
  defp safe_subtract(a, b), do: a - b

  ## Video Products

  @spec add_product_to_video(pos_integer(), pos_integer(), String.t() | nil) ::
          {:ok, CreatorVideoProduct.t()} | {:error, Ecto.Changeset.t()}
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

  @spec mark_sample_fulfilled(CreatorSample.t(), CreatorVideo.t()) ::
          {:ok, CreatorSample.t()} | {:error, Ecto.Changeset.t()}
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

  @spec auto_attribute_video_to_sample(CreatorVideo.t()) ::
          {:ok, CreatorSample.t()} | {:ok, nil} | {:error, Ecto.Changeset.t()}
  @doc """
  Attempts to auto-attribute a video to an unfulfilled sample using strict product matching.
  Only matches if the video's products include the sample's product_id.

  Returns {:ok, sample} if a match is found and attributed, or {:ok, nil} if no match.
  """
  def auto_attribute_video_to_sample(video) do
    # Get creator's unfulfilled samples
    unfulfilled_samples = get_unfulfilled_samples_for_creator(video.brand_id, video.creator_id)

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

  @spec get_unfulfilled_samples_for_creator(pos_integer()) :: [CreatorSample.t()]
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

  @spec get_unfulfilled_samples_for_creator(pos_integer(), pos_integer()) :: [CreatorSample.t()]
  def get_unfulfilled_samples_for_creator(brand_id, creator_id) do
    from(s in CreatorSample,
      where: s.brand_id == ^brand_id and s.creator_id == ^creator_id,
      where: s.fulfilled == false or is_nil(s.fulfilled),
      where: not is_nil(s.product_id),
      order_by: [desc: s.ordered_at]
    )
    |> Repo.all()
  end

  @spec get_product_ids_for_video(pos_integer()) :: [pos_integer()]
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

  @spec get_fulfillment_stats(pos_integer()) ::
          %{
            total_samples: non_neg_integer(),
            fulfilled: non_neg_integer(),
            unfulfilled: non_neg_integer(),
            fulfillment_rate: float()
          }
          | nil
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

  @spec get_fulfillment_stats(pos_integer(), pos_integer()) ::
          %{
            total_samples: non_neg_integer(),
            fulfilled: non_neg_integer(),
            unfulfilled: non_neg_integer(),
            fulfillment_rate: float()
          }
          | nil
  def get_fulfillment_stats(brand_id, creator_id) do
    total =
      from(s in CreatorSample,
        where: s.brand_id == ^brand_id and s.creator_id == ^creator_id,
        select: count()
      )
      |> Repo.one()

    fulfilled =
      from(s in CreatorSample,
        where: s.brand_id == ^brand_id and s.creator_id == ^creator_id and s.fulfilled == true,
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
      nil
  end

  ## Performance Snapshots

  @spec create_performance_snapshot(pos_integer(), map()) ::
          {:ok, CreatorPerformanceSnapshot.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Creates a performance snapshot.
  """
  def create_performance_snapshot(brand_id, attrs \\ %{}) do
    %CreatorPerformanceSnapshot{brand_id: brand_id}
    |> CreatorPerformanceSnapshot.changeset(attrs)
    |> Repo.insert()
  end

  @spec get_latest_snapshot(pos_integer(), pos_integer()) :: CreatorPerformanceSnapshot.t() | nil
  @doc """
  Gets the latest performance snapshot for a creator.
  """
  def get_latest_snapshot(brand_id, creator_id) do
    from(s in CreatorPerformanceSnapshot,
      where: s.brand_id == ^brand_id and s.creator_id == ^creator_id,
      order_by: [desc: s.snapshot_date],
      limit: 1
    )
    |> Repo.one()
  end

  @spec list_snapshots_for_creator(pos_integer(), pos_integer()) :: [
          CreatorPerformanceSnapshot.t()
        ]
  @doc """
  Lists performance snapshots for a creator.
  """
  def list_snapshots_for_creator(brand_id, creator_id) do
    from(s in CreatorPerformanceSnapshot,
      where: s.brand_id == ^brand_id and s.creator_id == ^creator_id,
      order_by: [desc: s.snapshot_date]
    )
    |> Repo.all()
  end

  ## BigQuery Sync Helpers

  @spec find_creators_by_handles(String.t() | any()) :: {[Creator.t()], [String.t()]}
  @doc """
  Finds creators by a list of TikTok handles in various formats.

  Handles are normalized (stripped of @, extracted from URLs, lowercased).
  Searches both current `tiktok_username` and `previous_tiktok_usernames`.

  ## Input formats supported
    - Plain: `johnsmith123`
    - With @: `@johnsmith123`
    - TikTok URLs: `https://www.tiktok.com/@johnsmith123`
    - Separators: comma, space, tab, newline

  ## Returns
    `{found_creators, not_found_handles}` tuple where:
    - `found_creators` is a list of Creator structs
    - `not_found_handles` is a list of normalized handles that weren't found
  """
  def find_creators_by_handles(input) when is_binary(input) do
    handles =
      input
      |> String.split(~r/[\s,]+/)
      |> Enum.map(&normalize_handle/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if handles == [] do
      {[], []}
    else
      find_creators_by_normalized_handles(handles)
    end
  end

  def find_creators_by_handles(_), do: {[], []}

  @spec find_creators_by_handles(pos_integer(), String.t() | any()) ::
          {[Creator.t()], [String.t()]}
  def find_creators_by_handles(brand_id, input) when is_binary(input) do
    handles =
      input
      |> String.split(~r/[\s,]+/)
      |> Enum.map(&normalize_handle/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if handles == [] do
      {[], []}
    else
      find_creators_by_normalized_handles(brand_id, handles)
    end
  end

  def find_creators_by_handles(_brand_id, _), do: {[], []}

  defp normalize_handle(raw) do
    raw = String.trim(raw)

    # Extract username from TikTok URL if present
    username =
      case Regex.run(~r{tiktok\.com/@?([^/?]+)}, raw) do
        [_, username] -> username
        nil -> raw
      end

    # Strip leading @ and lowercase
    username
    |> String.trim_leading("@")
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp find_creators_by_normalized_handles(handles) do
    # First query: find by current username
    found_by_username =
      from(c in Creator,
        where: c.tiktok_username in ^handles
      )
      |> Repo.all()

    found_usernames = Enum.map(found_by_username, &String.downcase(&1.tiktok_username))
    remaining_handles = handles -- found_usernames

    # Second query: find by previous usernames for remaining handles
    found_by_previous =
      if remaining_handles == [] do
        []
      else
        from(c in Creator,
          where:
            fragment(
              "EXISTS (SELECT 1 FROM unnest(?) AS prev WHERE LOWER(prev) = ANY(?))",
              c.previous_tiktok_usernames,
              ^remaining_handles
            )
        )
        |> Repo.all()
      end

    # Calculate which handles from remaining were found via previous usernames
    found_previous_handles =
      Enum.flat_map(found_by_previous, fn creator ->
        (creator.previous_tiktok_usernames || [])
        |> Enum.map(&String.downcase/1)
        |> Enum.filter(&(&1 in remaining_handles))
      end)

    not_found_handles = remaining_handles -- found_previous_handles

    # Combine results, removing duplicates (same creator found via both paths)
    all_found = (found_by_username ++ found_by_previous) |> Enum.uniq_by(& &1.id)

    {all_found, not_found_handles}
  end

  defp find_creators_by_normalized_handles(brand_id, handles) do
    found_by_username =
      from(c in Creator,
        join: bc in BrandCreator,
        on: bc.creator_id == c.id,
        where: bc.brand_id == ^brand_id and c.tiktok_username in ^handles
      )
      |> Repo.all()

    found_usernames = Enum.map(found_by_username, &String.downcase(&1.tiktok_username))
    remaining_handles = handles -- found_usernames

    found_by_previous =
      if remaining_handles == [] do
        []
      else
        from(c in Creator,
          join: bc in BrandCreator,
          on: bc.creator_id == c.id,
          where:
            bc.brand_id == ^brand_id and
              fragment(
                "EXISTS (SELECT 1 FROM unnest(?) AS prev WHERE LOWER(prev) = ANY(?))",
                c.previous_tiktok_usernames,
                ^remaining_handles
              )
        )
        |> Repo.all()
      end

    found_previous_handles =
      Enum.flat_map(found_by_previous, fn creator ->
        (creator.previous_tiktok_usernames || [])
        |> Enum.map(&String.downcase/1)
        |> Enum.filter(&(&1 in remaining_handles))
      end)

    not_found_handles = remaining_handles -- found_previous_handles

    all_found = (found_by_username ++ found_by_previous) |> Enum.uniq_by(& &1.id)

    {all_found, not_found_handles}
  end

  @spec get_creator_by_tiktok_user_id(String.t() | nil) :: Creator.t() | nil
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

  @spec get_creator_by_previous_username(String.t() | nil) :: Creator.t() | nil
  @doc """
  Gets a creator by a previous TikTok username.

  Searches the `previous_tiktok_usernames` array for creators who used to have
  this handle before changing it. Useful for:
  - Preventing duplicates when adding a creator by their old handle
  - Finding the correct creator record when given an outdated handle

  Returns nil if not found or if username is nil/empty.
  """
  def get_creator_by_previous_username(nil), do: nil
  def get_creator_by_previous_username(""), do: nil

  def get_creator_by_previous_username(username) when is_binary(username) do
    normalized = String.downcase(String.trim(username))

    from(c in Creator,
      where: ^normalized in fragment("SELECT LOWER(unnest(?))", c.previous_tiktok_usernames),
      limit: 1
    )
    |> Repo.one()
  end

  @spec get_creator_by_any_username(String.t() | nil) :: Creator.t() | nil
  @doc """
  Finds a creator by username, checking both current and previous handles.

  First checks current `tiktok_username`, then falls back to `previous_tiktok_usernames`.
  This is the recommended function to use when you have a username and want to
  find the creator regardless of whether they've changed their handle.

  Returns nil if not found.
  """
  def get_creator_by_any_username(nil), do: nil
  def get_creator_by_any_username(""), do: nil

  def get_creator_by_any_username(username) when is_binary(username) do
    get_creator_by_username(username) || get_creator_by_previous_username(username)
  end

  @spec get_creator_by_phone(String.t() | nil) :: Creator.t() | nil
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

  @spec get_creator_by_name(String.t() | nil, String.t() | nil) :: Creator.t() | nil
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

  @spec list_existing_order_ids() :: MapSet.t(String.t())
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

  @spec list_existing_order_ids(pos_integer()) :: MapSet.t(String.t())
  def list_existing_order_ids(brand_id) do
    from(cs in CreatorSample,
      where: cs.brand_id == ^brand_id and not is_nil(cs.tiktok_order_id),
      select: cs.tiktok_order_id,
      distinct: true
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @spec parse_name(String.t() | nil) :: {String.t() | nil, String.t() | nil}
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

  @spec list_tags_for_brand(pos_integer()) :: [CreatorTag.t()]
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

  @spec get_tag!(pos_integer()) :: CreatorTag.t() | no_return()
  @doc """
  Gets a single tag by ID.
  Raises `Ecto.NoResultsError` if not found.
  """
  def get_tag!(id), do: Repo.get!(CreatorTag, id)

  @spec get_tag!(pos_integer(), pos_integer()) :: CreatorTag.t() | no_return()
  def get_tag!(brand_id, id), do: Repo.get_by!(CreatorTag, id: id, brand_id: brand_id)

  @spec get_tag(pos_integer()) :: CreatorTag.t() | nil
  @doc """
  Gets a tag by ID, returns nil if not found.
  """
  def get_tag(id), do: Repo.get(CreatorTag, id)

  @spec get_tag(pos_integer(), pos_integer()) :: CreatorTag.t() | nil
  def get_tag(brand_id, id), do: Repo.get_by(CreatorTag, id: id, brand_id: brand_id)

  @spec get_tag_by_name(pos_integer(), String.t()) :: CreatorTag.t() | nil
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

  @spec create_tag(map()) :: {:ok, CreatorTag.t()} | {:error, Ecto.Changeset.t()}
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

  @spec update_tag(CreatorTag.t(), map()) :: {:ok, CreatorTag.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Updates a tag.
  """
  def update_tag(%CreatorTag{} = tag, attrs) do
    tag
    |> CreatorTag.changeset(attrs)
    |> Repo.update()
  end

  @spec delete_tag(CreatorTag.t()) :: {:ok, CreatorTag.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Deletes a tag. Also removes all assignments.
  """
  def delete_tag(%CreatorTag{} = tag) do
    Repo.delete(tag)
  end

  @spec count_creators_for_tag(pos_integer()) :: non_neg_integer()
  @doc """
  Counts how many creators have a specific tag assigned.
  """
  def count_creators_for_tag(tag_id) do
    from(a in CreatorTagAssignment, where: a.creator_tag_id == ^tag_id, select: count(a.id))
    |> Repo.one()
  end

  ## Tag Assignments

  @spec list_tags_for_creator(pos_integer(), pos_integer() | nil) :: [CreatorTag.t()]
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

  @spec batch_list_tags_for_creators([pos_integer()], pos_integer() | nil) :: %{
          optional(pos_integer()) => [CreatorTag.t()]
        }
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

  @spec assign_tag_to_creator(pos_integer(), pos_integer()) ::
          {:ok, CreatorTagAssignment.t()}
          | {:ok, :already_assigned}
          | {:error, Ecto.Changeset.t()}
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

  @spec remove_tag_from_creator(pos_integer(), pos_integer()) :: {:ok, non_neg_integer()}
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

  @spec set_creator_tags(pos_integer(), [pos_integer()]) ::
          {:ok, non_neg_integer()} | {:error, any()}
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

  @spec batch_assign_tags([pos_integer()], [pos_integer()]) :: {:ok, non_neg_integer()}
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

  @spec get_tag_ids_for_creator(pos_integer()) :: [pos_integer()]
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

  @spec get_tag_ids_for_creator(pos_integer(), pos_integer()) :: [pos_integer()]
  def get_tag_ids_for_creator(brand_id, creator_id) do
    from(a in CreatorTagAssignment,
      join: t in CreatorTag,
      on: a.creator_tag_id == t.id,
      where: a.creator_id == ^creator_id and t.brand_id == ^brand_id,
      select: a.creator_tag_id
    )
    |> Repo.all()
  end

  ## Creator Purchases

  @spec create_purchase(pos_integer(), map()) ::
          {:ok, CreatorPurchase.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Creates a creator purchase record.
  Uses on_conflict: :nothing to handle duplicates gracefully.
  """
  def create_purchase(brand_id, attrs \\ %{}) do
    %CreatorPurchase{brand_id: brand_id}
    |> CreatorPurchase.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :tiktok_order_id)
  end

  @spec list_purchases_for_creator(pos_integer(), pos_integer()) :: [CreatorPurchase.t()]
  @doc """
  Lists purchases for a creator, ordered by date descending.
  """
  def list_purchases_for_creator(brand_id, creator_id) do
    from(p in CreatorPurchase,
      where: p.brand_id == ^brand_id and p.creator_id == ^creator_id,
      order_by: [desc: p.ordered_at]
    )
    |> Repo.all()
  end

  @spec get_purchase_stats(pos_integer(), pos_integer()) :: %{
          purchase_count: non_neg_integer(),
          total_spent_cents: non_neg_integer(),
          paid_purchase_count: non_neg_integer()
        }
  @doc """
  Gets purchase statistics for a creator.
  Returns %{purchase_count: n, total_spent_cents: n, paid_purchase_count: n}
  """
  def get_purchase_stats(brand_id, creator_id) do
    from(p in CreatorPurchase,
      where: p.brand_id == ^brand_id and p.creator_id == ^creator_id,
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
          where:
            p.brand_id == ^brand_id and p.creator_id == ^creator_id and p.is_sample_order == false,
          select: count(p.id)
        )
        |> Repo.one()

      Map.put(stats, :paid_purchase_count, paid_count)
    end)
  end

  @spec get_purchases_for_modal(pos_integer()) :: [CreatorPurchase.t()]
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

  @spec get_purchases_for_modal(pos_integer(), pos_integer()) :: [CreatorPurchase.t()]
  def get_purchases_for_modal(brand_id, creator_id) do
    from(p in CreatorPurchase,
      where: p.brand_id == ^brand_id and p.creator_id == ^creator_id,
      order_by: [desc: p.ordered_at],
      limit: 50
    )
    |> Repo.all()
  end

  @spec list_existing_purchase_order_ids() :: MapSet.t(String.t())
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

  @spec list_existing_purchase_order_ids(pos_integer()) :: MapSet.t(String.t())
  def list_existing_purchase_order_ids(brand_id) do
    from(p in CreatorPurchase,
      where: p.brand_id == ^brand_id,
      select: p.tiktok_order_id,
      distinct: true
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @spec batch_count_purchases([pos_integer()]) :: %{optional(pos_integer()) => non_neg_integer()}
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

  @spec batch_count_purchases(pos_integer(), [pos_integer()]) :: %{
          optional(pos_integer()) => non_neg_integer()
        }
  def batch_count_purchases(brand_id, creator_ids) when is_list(creator_ids) do
    if creator_ids == [] do
      %{}
    else
      from(p in CreatorPurchase,
        where:
          p.brand_id == ^brand_id and p.creator_id in ^creator_ids and
            p.is_sample_order == false,
        group_by: p.creator_id,
        select: {p.creator_id, count(p.id)}
      )
      |> Repo.all()
      |> Map.new()
    end
  end

  ## Import Audits

  alias SocialObjects.Creators.ImportAudit

  @spec create_import_audit(map()) :: {:ok, ImportAudit.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Creates an import audit record to track an import run.
  """
  def create_import_audit(attrs) do
    %ImportAudit{}
    |> ImportAudit.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_import_audit(ImportAudit.t(), map()) ::
          {:ok, ImportAudit.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Updates an import audit record with new status or counts.
  """
  def update_import_audit(audit, attrs) do
    audit
    |> ImportAudit.changeset(attrs)
    |> Repo.update()
  end

  @spec get_import_audit!(pos_integer()) :: ImportAudit.t()
  @doc """
  Gets an import audit by ID.
  """
  def get_import_audit!(id), do: Repo.get!(ImportAudit, id)

  @spec compute_file_checksum(String.t()) :: String.t()
  @doc """
  Computes MD5 checksum of a file for duplicate detection.
  """
  def compute_file_checksum(file_path) do
    File.stream!(file_path, 2048)
    |> Enum.reduce(:crypto.hash_init(:md5), fn chunk, acc ->
      :crypto.hash_update(acc, chunk)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @spec can_import_file?(pos_integer(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :already_imported}
  @doc """
  Checks if a file can be imported (not already running or completed).

  Returns {:ok, checksum} if import can proceed, or {:error, :already_imported}
  if a running or completed import exists for this file.
  """
  def can_import_file?(brand_id, source, file_path) do
    checksum = compute_file_checksum(file_path)

    existing =
      Repo.exists?(
        from(a in ImportAudit,
          where:
            a.brand_id == ^brand_id and
              a.source == ^source and
              a.file_checksum == ^checksum and
              a.status in ["running", "completed"]
        )
      )

    if existing do
      {:error, :already_imported}
    else
      {:ok, checksum}
    end
  end

  ## Quality-Aware Creator Upsert with Manual-Edit Protection

  @spec upsert_creator_with_protection(map(), keyword()) ::
          {:ok, Creator.t(), :created | :updated} | {:error, Ecto.Changeset.t()}
  @doc """
  Upserts a creator with quality-aware contact merging and manual-edit protection.

  Unlike the regular `upsert_creator/1`, this function:
  - Respects `manually_edited_fields` - never overwrites manually edited data
  - Uses quality-aware merging - replaces low-quality data with high-quality data
  - Detects low-quality data patterns (masked values, redirect emails)

  ## Options
    - `:update_enrichment` - If true, sets `last_enriched_at` and `enrichment_source`

  Returns `{:ok, creator, :created}` or `{:ok, creator, :updated}` or `{:error, changeset}`.
  """
  def upsert_creator_with_protection(attrs, opts \\ []) do
    username = attrs[:tiktok_username] || attrs["tiktok_username"]

    case get_creator_by_any_username(username) do
      nil -> create_protected_creator(attrs)
      existing -> update_protected_creator(existing, attrs, opts)
    end
  end

  defp create_protected_creator(attrs) do
    sanitized = sanitize_contact_attrs(attrs)

    case create_creator(sanitized) do
      {:ok, creator} -> {:ok, creator, :created}
      error -> error
    end
  end

  defp update_protected_creator(existing, attrs, opts) do
    updates =
      existing
      |> build_protected_attrs(attrs)
      |> maybe_add_enrichment_fields(opts)

    if map_size(updates) > 0 do
      case update_creator(existing, updates) do
        {:ok, creator} -> {:ok, creator, :updated}
        error -> error
      end
    else
      {:ok, existing, :updated}
    end
  end

  defp maybe_add_enrichment_fields(updates, opts) do
    if Keyword.get(opts, :update_enrichment, false) do
      Map.merge(updates, %{
        last_enriched_at: DateTime.utc_now(),
        enrichment_source: Keyword.get(opts, :enrichment_source, "external_import")
      })
    else
      updates
    end
  end

  defp build_protected_attrs(existing, new_attrs) do
    # Note: manually_edited_fields has default: [] in schema, so it's always a list
    protected = existing.manually_edited_fields

    [
      :email,
      :phone,
      :first_name,
      :last_name,
      :address_line_1,
      :address_line_2,
      :city,
      :state,
      :zipcode
    ]
    |> Enum.reduce(%{}, fn field, acc ->
      existing_val = Map.get(existing, field)
      new_val = sanitize_contact_field(field, get_attr(new_attrs, field))

      if should_update_field?(existing_val, new_val, field, protected) do
        Map.put(acc, field, new_val)
      else
        acc
      end
    end)
  end

  # Quality-aware field update logic:
  # 1. Never update to nil/empty values
  # 2. Never overwrite manually edited fields
  # 3. Always fill blanks (existing is nil/empty)
  # 4. Replace low-quality with high-quality data
  # 5. Don't overwrite existing high-quality data

  defp should_update_field?(_existing, nil, _field, _protected), do: false
  defp should_update_field?(_existing, "", _field, _protected), do: false

  defp should_update_field?(existing, new_value, field, protected) do
    field_str = to_string(field)

    cond do
      # Never overwrite manually edited fields
      field_str in protected ->
        false

      # Always fill blanks
      is_nil(existing) or existing == "" ->
        true

      # Don't replace with low-quality data
      low_quality?(new_value) ->
        false

      # Replace low-quality existing data with high-quality new data
      low_quality?(existing) and not low_quality?(new_value) ->
        true

      # Don't overwrite existing high-quality data
      true ->
        false
    end
  end

  # Detect low-quality data patterns
  defp low_quality?(nil), do: true
  defp low_quality?(""), do: true

  defp low_quality?(value) when is_binary(value) do
    # Masked values (contains asterisks)
    # Redirect/temp emails
    # Placeholder patterns
    String.contains?(value, "*") or
      String.contains?(value, "@redirect.") or
      String.contains?(value, "@temp.") or
      String.downcase(value) in ["n/a", "na", "none", "unknown", "test"]
  end

  defp low_quality?(_), do: false

  defp sanitize_contact_attrs(attrs) do
    attrs
    |> maybe_sanitize_field(:email, &sanitize_email/1)
    |> maybe_sanitize_field(:phone, &sanitize_phone/1)
    |> maybe_sanitize_field("email", &sanitize_email/1)
    |> maybe_sanitize_field("phone", &sanitize_phone/1)
  end

  defp maybe_sanitize_field(attrs, key, sanitizer) when is_map(attrs) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> Map.put(attrs, key, sanitizer.(value))
      :error -> attrs
    end
  end

  defp sanitize_contact_field(:email, value), do: sanitize_email(value)
  defp sanitize_contact_field(:phone, value), do: sanitize_phone(value)
  defp sanitize_contact_field(_field, value), do: blank_to_nil(value)

  defp sanitize_email(nil), do: nil
  defp sanitize_email(""), do: nil

  defp sanitize_email(email) when is_binary(email) do
    email = String.trim(email)

    # Basic email validation - must have @ and domain
    if Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email) do
      String.downcase(email)
    else
      nil
    end
  end

  defp sanitize_phone(nil), do: nil
  defp sanitize_phone(""), do: nil

  defp sanitize_phone(phone) when is_binary(phone) do
    normalized = normalize_phone(phone)

    if normalized do
      # Keep if it has enough digits (after normalization)
      digits = String.replace(normalized, ~r/\D/, "")

      if String.length(digits) >= 10 do
        normalized
      else
        nil
      end
    else
      nil
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(val) when is_binary(val),
    do: if(String.trim(val) == "", do: nil, else: String.trim(val))

  defp blank_to_nil(val), do: val
end
