defmodule SocialObjects.CreatorsEngagementFiltersTest do
  use SocialObjects.DataCase, async: true

  alias SocialObjects.Creators

  test "search_creators_unified supports segment filters" do
    brand = brand_fixture()

    vip_creator = creator_with_brand_creator(brand.id, %{is_vip: true})
    trending_creator = creator_with_brand_creator(brand.id, %{is_trending: true})
    high_priority_creator = creator_with_brand_creator(brand.id, %{engagement_priority: :high})

    monitor_creator =
      creator_with_brand_creator(brand.id, %{engagement_priority: :monitor, is_vip: true})

    _other_creator = creator_with_brand_creator(brand.id, %{})

    vip_result = Creators.search_creators_unified(brand_id: brand.id, segment: "vip")
    assert Enum.any?(vip_result.creators, &(&1.id == vip_creator.id))

    trending_result = Creators.search_creators_unified(brand_id: brand.id, segment: "trending")
    assert Enum.any?(trending_result.creators, &(&1.id == trending_creator.id))

    high_priority_result =
      Creators.search_creators_unified(brand_id: brand.id, segment: "high_priority")

    assert Enum.any?(high_priority_result.creators, &(&1.id == high_priority_creator.id))

    attention_result =
      Creators.search_creators_unified(brand_id: brand.id, segment: "needs_attention")

    assert Enum.any?(attention_result.creators, &(&1.id == monitor_creator.id))
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
