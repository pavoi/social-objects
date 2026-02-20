defmodule SocialObjectsWeb.CreatorsLiveTest do
  use SocialObjectsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import SocialObjects.AccountsFixtures
  import SocialObjects.TiktokLiveFixtures

  alias SocialObjects.Accounts
  alias SocialObjects.Creators

  setup %{conn: conn} do
    brand = brand_fixture()
    user = user_fixture()
    {:ok, _user_brand} = Accounts.create_user_brand(user, brand, :admin)

    conn = log_in_user(conn, user)
    path = "/b/#{brand.slug}/creators"

    %{conn: conn, brand: brand, path: path}
  end

  test "segment filter narrows creators and coexists with period filter", %{
    conn: conn,
    brand: brand,
    path: path
  } do
    vip_elite_creator =
      creator_for_brand(brand.id, %{engagement_priority: :vip_elite, brand_gmv_cents: 100_000})

    _other_creator =
      creator_for_brand(brand.id, %{engagement_priority: nil, brand_gmv_cents: 50_000})

    {:ok, view, _html} = live(conn, path)

    view
    |> element("#segment-filter [phx-value-selection='vip_elite']")
    |> render_click()

    assert_patch(view, "#{path}?segment=vip_elite")
    assert has_element?(view, "tr[phx-value-id='#{vip_elite_creator.id}']")

    view
    |> element("button[phx-click='set_time_preset'][phx-value-preset='30d']")
    |> render_click()

    patched_path = assert_patch(view)
    assert patched_path =~ "segment=vip_elite"
    assert patched_path =~ "period=30"
  end

  test "system badges render separately from manual tags", %{conn: conn, brand: brand, path: path} do
    creator =
      creator_for_brand(brand.id, %{
        is_vip: true,
        is_trending: true,
        engagement_priority: :vip_elite
      })

    {:ok, tag} =
      Creators.create_tag(%{
        brand_id: brand.id,
        name: "ManualTag",
        color: "blue"
      })

    _ = Creators.assign_tag_to_creator(creator.id, tag.id)

    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "#system-badges-#{creator.id}", "VIP")
    assert has_element?(view, "#system-badges-#{creator.id}", "Trending")
    assert has_element?(view, "#system-badges-#{creator.id}", "VIP Elite")

    assert has_element?(view, "#tag-cell-#{creator.id} [data-tag]", "ManualTag")
    refute has_element?(view, "#tag-cell-#{creator.id} .badge", "VIP")
  end

  test "next touchpoint schedule filter supports due_this_week", %{
    conn: conn,
    brand: brand,
    path: path
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    due_creator =
      creator_for_brand(brand.id, %{
        next_touchpoint_at: DateTime.add(now, 2 * 86_400, :second)
      })

    far_creator =
      creator_for_brand(brand.id, %{
        next_touchpoint_at: DateTime.add(now, 20 * 86_400, :second)
      })

    {:ok, view, _html} = live(conn, path)

    view
    |> element("#next-touchpoint-state-filter [phx-value-selection='due_this_week']")
    |> render_click()

    assert_patch(view, "#{path}?next_touchpoint_state=due_this_week")
    assert has_element?(view, "tr[phx-value-id='#{due_creator.id}']")
    refute has_element?(view, "tr[phx-value-id='#{far_creator.id}']")
  end

  test "engagement fields can be updated inline in table", %{conn: conn, brand: brand, path: path} do
    creator =
      creator_for_brand(brand.id, %{
        last_touchpoint_type: nil,
        preferred_contact_channel: nil
      })

    {:ok, view, _html} = live(conn, path)

    view
    |> form("#inline-engagement-#{creator.id}-preferred_contact_channel",
      inline_engagement: %{
        "creator_id" => Integer.to_string(creator.id),
        "field" => "preferred_contact_channel",
        "value" => "sms"
      }
    )
    |> render_change()

    view
    |> form("#inline-engagement-#{creator.id}-last_touchpoint_type",
      inline_engagement: %{
        "creator_id" => Integer.to_string(creator.id),
        "field" => "last_touchpoint_type",
        "value" => "email"
      }
    )
    |> render_change()

    brand_creator = Creators.get_brand_creator(brand.id, creator.id)
    assert brand_creator.preferred_contact_channel == :sms
    assert brand_creator.last_touchpoint_type == :email
  end

  defp creator_for_brand(brand_id, brand_creator_attrs) do
    unique = System.unique_integer([:positive])

    {:ok, creator} =
      Creators.create_creator(%{
        tiktok_username: "creators-live-#{unique}"
      })

    _ = Creators.add_creator_to_brand(creator.id, brand_id)

    brand_creator = Creators.get_brand_creator(brand_id, creator.id)
    {:ok, _updated} = Creators.update_brand_creator(brand_creator, brand_creator_attrs)

    creator
  end
end
