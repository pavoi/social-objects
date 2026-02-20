defmodule SocialObjects.CreatorsEngagementFiltersTest do
  use SocialObjects.DataCase, async: true

  alias SocialObjects.Creators
  alias SocialObjects.Creators.CreatorSample
  alias SocialObjects.Repo

  test "search_creators_unified supports MECE segment filters" do
    brand = brand_fixture()

    rising_star_creator =
      creator_with_brand_creator(brand.id, %{engagement_priority: :rising_star})

    vip_elite_creator = creator_with_brand_creator(brand.id, %{engagement_priority: :vip_elite})
    vip_stable_creator = creator_with_brand_creator(brand.id, %{engagement_priority: :vip_stable})

    vip_at_risk_creator =
      creator_with_brand_creator(brand.id, %{engagement_priority: :vip_at_risk})

    _other_creator = creator_with_brand_creator(brand.id, %{})

    rising_star_result =
      Creators.search_creators_unified(brand_id: brand.id, segment: "rising_star")

    assert Enum.any?(rising_star_result.creators, &(&1.id == rising_star_creator.id))

    vip_elite_result = Creators.search_creators_unified(brand_id: brand.id, segment: "vip_elite")
    assert Enum.any?(vip_elite_result.creators, &(&1.id == vip_elite_creator.id))

    vip_stable_result =
      Creators.search_creators_unified(brand_id: brand.id, segment: "vip_stable")

    assert Enum.any?(vip_stable_result.creators, &(&1.id == vip_stable_creator.id))

    vip_at_risk_result =
      Creators.search_creators_unified(brand_id: brand.id, segment: "vip_at_risk")

    assert Enum.any?(vip_at_risk_result.creators, &(&1.id == vip_at_risk_creator.id))
  end

  test "search_creators_unified supports touchpoint filters and next_touchpoint sorting" do
    brand = brand_fixture()

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    tomorrow = DateTime.add(now, 86_400, :second)
    next_month = DateTime.add(now, 30 * 86_400, :second)
    yesterday = DateTime.add(now, -86_400, :second)

    email_creator =
      creator_with_brand_creator(brand.id, %{
        last_touchpoint_type: :email,
        preferred_contact_channel: :email,
        next_touchpoint_at: tomorrow
      })

    sms_creator =
      creator_with_brand_creator(brand.id, %{
        last_touchpoint_type: :sms,
        preferred_contact_channel: :sms,
        next_touchpoint_at: yesterday
      })

    far_scheduled_creator =
      creator_with_brand_creator(brand.id, %{
        last_touchpoint_type: :manual,
        preferred_contact_channel: :email,
        next_touchpoint_at: next_month
      })

    _manual_creator =
      creator_with_brand_creator(brand.id, %{
        last_touchpoint_type: :manual,
        preferred_contact_channel: :tiktok_dm,
        next_touchpoint_at: nil
      })

    email_type_result =
      Creators.search_creators_unified(brand_id: brand.id, last_touchpoint_type: "email")

    assert Enum.map(email_type_result.creators, & &1.id) == [email_creator.id]

    sms_channel_result =
      Creators.search_creators_unified(brand_id: brand.id, preferred_contact_channel: "sms")

    assert Enum.map(sms_channel_result.creators, & &1.id) == [sms_creator.id]

    scheduled_result =
      Creators.search_creators_unified(brand_id: brand.id, next_touchpoint_state: "scheduled")

    scheduled_ids = Enum.map(scheduled_result.creators, & &1.id)
    assert email_creator.id in scheduled_ids
    assert far_scheduled_creator.id in scheduled_ids

    due_this_week_result =
      Creators.search_creators_unified(brand_id: brand.id, next_touchpoint_state: "due_this_week")

    assert Enum.map(due_this_week_result.creators, & &1.id) == [email_creator.id]

    overdue_result =
      Creators.search_creators_unified(brand_id: brand.id, next_touchpoint_state: "overdue")

    assert Enum.map(overdue_result.creators, & &1.id) == [sms_creator.id]

    sorted_result =
      Creators.search_creators_unified(
        brand_id: brand.id,
        sort_by: "next_touchpoint",
        sort_dir: "asc"
      )

    ids = Enum.map(sorted_result.creators, & &1.id)
    assert Enum.at(ids, 0) == sms_creator.id
    assert Enum.at(ids, 1) == email_creator.id
  end

  test "get_engagement_filter_stats returns counts for engagement tracking dropdowns" do
    brand = brand_fixture()

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    due_this_week = DateTime.add(now, 2 * 86_400, :second)
    scheduled_later = DateTime.add(now, 20 * 86_400, :second)
    overdue = DateTime.add(now, -86_400, :second)

    _email_creator =
      creator_with_brand_creator(brand.id, %{
        last_touchpoint_type: :email,
        preferred_contact_channel: :email,
        next_touchpoint_at: due_this_week
      })

    _sms_creator =
      creator_with_brand_creator(brand.id, %{
        last_touchpoint_type: :sms,
        preferred_contact_channel: :sms,
        next_touchpoint_at: overdue
      })

    _manual_scheduled_creator =
      creator_with_brand_creator(brand.id, %{
        last_touchpoint_type: :manual,
        preferred_contact_channel: :email,
        next_touchpoint_at: scheduled_later
      })

    _manual_unscheduled_creator =
      creator_with_brand_creator(brand.id, %{
        last_touchpoint_type: :manual,
        preferred_contact_channel: :tiktok_dm,
        next_touchpoint_at: nil
      })

    stats = Creators.get_engagement_filter_stats(brand.id)

    assert stats.last_touchpoint_type == %{email: 1, sms: 1, manual: 2}
    assert stats.preferred_contact_channel == %{email: 2, sms: 1, tiktok_dm: 1}

    assert stats.next_touchpoint_state == %{
             scheduled: 2,
             due_this_week: 1,
             overdue: 1,
             unscheduled: 1
           }
  end

  test "update_brand_creator_engagement ignores manual engagement_priority input" do
    brand = brand_fixture()
    creator = creator_with_brand_creator(brand.id, %{engagement_priority: :medium})
    brand_creator = Creators.get_brand_creator(brand.id, creator.id)
    date_string = "2026-03-15"

    assert {:ok, updated} =
             Creators.update_brand_creator_engagement(brand.id, creator.id, %{
               "engagement_priority" => "high",
               "next_touchpoint_at" => date_string
             })

    assert updated.engagement_priority == :medium
    assert DateTime.to_date(updated.next_touchpoint_at) == ~D[2026-03-15]
    assert updated.next_touchpoint_at.hour == 0
    assert updated.id == brand_creator.id
  end

  test "search_creators_unified hide_inactive excludes creators with zero samples and zero GMV" do
    brand = brand_fixture()

    inactive_creator =
      creator_with_brand_creator(brand.id, %{cumulative_brand_gmv_cents: 0, brand_gmv_cents: 0})

    gmv_creator =
      creator_with_brand_creator(brand.id, %{
        cumulative_brand_gmv_cents: 50_000,
        brand_gmv_cents: 0
      })

    sampled_creator =
      creator_with_brand_creator(brand.id, %{cumulative_brand_gmv_cents: 0, brand_gmv_cents: 0})

    _sample =
      Repo.insert!(%CreatorSample{
        creator_id: sampled_creator.id,
        brand_id: brand.id,
        quantity: 1,
        ordered_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    hidden_result =
      Creators.search_creators_unified(brand_id: brand.id, hide_inactive: true)

    hidden_ids = Enum.map(hidden_result.creators, & &1.id)
    assert gmv_creator.id in hidden_ids
    assert sampled_creator.id in hidden_ids
    refute inactive_creator.id in hidden_ids

    visible_result =
      Creators.search_creators_unified(brand_id: brand.id, hide_inactive: false)

    visible_ids = Enum.map(visible_result.creators, & &1.id)
    assert inactive_creator.id in visible_ids
  end

  defp creator_with_brand_creator(brand_id, brand_creator_attrs) do
    unique = System.unique_integer([:positive])

    {:ok, creator} =
      Creators.create_creator(%{
        tiktok_username: "engagement-filter-#{unique}"
      })

    _ = Creators.add_creator_to_brand(creator.id, brand_id)

    brand_creator = Creators.get_brand_creator(brand_id, creator.id)
    {:ok, _updated} = Creators.update_brand_creator(brand_creator, brand_creator_attrs)

    creator
  end
end
