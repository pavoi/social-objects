defmodule SocialObjectsWeb.VideosLiveTest do
  use SocialObjectsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import SocialObjects.AccountsFixtures
  import SocialObjects.TiktokLiveFixtures

  alias SocialObjects.Accounts
  alias SocialObjects.Creators
  alias SocialObjects.Repo

  describe "videos page filters" do
    setup %{conn: conn} do
      brand = brand_fixture()
      user = user_fixture()
      {:ok, _user_brand} = Accounts.create_user_brand(user, brand, :admin)

      # Create a creator for the brand
      {:ok, creator} =
        Creators.create_creator(%{
          brand_id: brand.id,
          tiktok_username: "testcreator",
          tiktok_nickname: "Test Creator"
        })

      # Create some videos with varied metrics
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      videos =
        for i <- 1..5 do
          {:ok, video} =
            %Creators.CreatorVideo{
              brand_id: brand.id,
              creator_id: creator.id
            }
            |> Creators.CreatorVideo.changeset(%{
              tiktok_video_id: "video_#{i}",
              title: "Test Video #{i}",
              gmv_cents: i * 100_000,
              gpm_cents: i * 10_000,
              impressions: i * 1000,
              ctr: Decimal.new("#{i}.5"),
              items_sold: i * 10,
              posted_at: DateTime.add(now, -i * 10, :day)
            })
            |> Repo.insert()

          video
        end

      insert_metric_snapshots(brand.id, videos)

      conn = log_in_user(conn, user)
      path = "/b/#{brand.slug}/videos"

      %{conn: conn, brand: brand, user: user, creator: creator, videos: videos, path: path}
    end

    test "renders videos page with default filters", %{conn: conn, path: path} do
      {:ok, view, html} = live(conn, path)

      # Should show videos count
      assert html =~ "videos"
      # Should have filter controls
      assert has_element?(view, ".video-filters")
      # Should have sort dropdown
      assert has_element?(view, "#sort-filter")
      assert has_element?(view, ".video-filters__sort-label", "Sort by:")
      assert has_element?(view, "#creator-filter [data-hover-dropdown-search]")

      assert has_element?(
               view,
               "#creator-filter [data-hover-dropdown-empty]",
               "No creators found"
             )
    end

    test "time preset filter persists in URL", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)

      # Click on L30d preset
      view
      |> element("button[phx-value-preset='30']")
      |> render_click()

      # Should redirect with period param
      assert_patch(view, "#{path}?period=30")
    end

    test "time preset loads from URL", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, "#{path}?period=90")

      # L90d button should be active
      assert has_element?(view, "button.preset-filter__btn--active[phx-value-preset='90']")
    end

    test "min GMV filter only visible when not sorting by GMV", %{conn: conn, path: path} do
      # Default sort is GMV - min GMV filter should be hidden
      {:ok, view, _html} = live(conn, path)

      # Min GMV filter should not be visible (dollar icon trigger)
      refute has_element?(view, ".preset-filter--min-gmv")

      # Switch to sort by views
      select_sort(view, "views_desc")

      patched_path = assert_patch(view)
      assert patched_path =~ "sort=views_desc"
      assert patched_path =~ "min_gmv=100000"

      # Now min GMV filter should be visible
      assert has_element?(view, ".preset-filter--min-gmv")
      assert has_element?(view, "button.preset-filter__btn--active[phx-value-amount='100000']")
    end

    test "min GMV filter persists in URL", %{conn: conn, path: path} do
      # First switch to non-GMV sort
      {:ok, view, _html} = live(conn, "#{path}?sort=views_desc")

      # Click on $5K preset
      view
      |> element("button[phx-value-amount='500000']")
      |> render_click()

      # Should be patched - wait for and verify the patch
      path_with_min_gmv = assert_patch(view)
      assert path_with_min_gmv =~ "min_gmv=500000"
    end

    test "min GMV auto-clears when switching to GMV sort", %{conn: conn, path: path} do
      # Start with views sort and min_gmv set
      {:ok, view, _html} = live(conn, "#{path}?sort=views_desc&min_gmv=100000")

      # Min GMV filter should be visible with value
      assert has_element?(view, ".preset-filter--min-gmv")

      # Switch to GMV sort
      select_sort(view, "gmv_desc")

      # URL should clear min_gmv when sorting by GMV
      assert_patch(view, path)

      # Min GMV filter should now be hidden (since we're sorting by GMV)
      refute has_element?(view, ".preset-filter--min-gmv")
    end

    test "combined filters work together", %{conn: conn, path: path} do
      # Load with multiple filters
      {:ok, view, _html} = live(conn, "#{path}?period=30&sort=views_desc&min_gmv=50000")

      # All filters should be active
      assert has_element?(view, "button.preset-filter__btn--active[phx-value-preset='30']")

      assert has_element?(
               view,
               "#sort-filter .hover-dropdown__item--selected[phx-value-selection='views_desc']"
             )

      assert has_element?(view, "button.preset-filter__btn--active[phx-value-amount='50000']")
    end

    test "period filter switches metric source without filtering by posted_at", %{
      conn: conn,
      path: path,
      brand: brand,
      creator: creator
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, all_time_leader} =
        %Creators.CreatorVideo{brand_id: brand.id, creator_id: creator.id}
        |> Creators.CreatorVideo.changeset(%{
          tiktok_video_id: "all-time-leader",
          title: "All Time Leader",
          gmv_cents: 2_000_000,
          gpm_cents: 50_000,
          impressions: 5_000,
          ctr: Decimal.new("4.5"),
          items_sold: 100,
          posted_at: DateTime.add(now, -220, :day)
        })
        |> Repo.insert()

      {:ok, period_leader} =
        %Creators.CreatorVideo{brand_id: brand.id, creator_id: creator.id}
        |> Creators.CreatorVideo.changeset(%{
          tiktok_video_id: "period-leader",
          title: "Period Leader",
          gmv_cents: 300_000,
          gpm_cents: 20_000,
          impressions: 4_000,
          ctr: Decimal.new("3.2"),
          items_sold: 20,
          posted_at: DateTime.add(now, -3, :day)
        })
        |> Repo.insert()

      _ =
        Creators.upsert_video_metric_snapshots([
          %{
            brand_id: brand.id,
            creator_video_id: all_time_leader.id,
            tiktok_video_id: all_time_leader.tiktok_video_id,
            snapshot_date: Date.utc_today(),
            window_days: 30,
            gmv_cents: 100_000,
            views: 2_000,
            items_sold: 10,
            gpm_cents: 10_000,
            ctr: Decimal.new("2.1")
          },
          %{
            brand_id: brand.id,
            creator_video_id: period_leader.id,
            tiktok_video_id: period_leader.tiktok_video_id,
            snapshot_date: Date.utc_today(),
            window_days: 30,
            gmv_cents: 800_000,
            views: 9_000,
            items_sold: 90,
            gpm_cents: 45_000,
            ctr: Decimal.new("6.5")
          },
          %{
            brand_id: brand.id,
            creator_video_id: all_time_leader.id,
            tiktok_video_id: all_time_leader.tiktok_video_id,
            snapshot_date: Date.utc_today(),
            window_days: 90,
            gmv_cents: 1_500_000,
            views: 15_000,
            items_sold: 120,
            gpm_cents: 45_000,
            ctr: Decimal.new("5.2")
          },
          %{
            brand_id: brand.id,
            creator_video_id: period_leader.id,
            tiktok_video_id: period_leader.tiktok_video_id,
            snapshot_date: Date.utc_today(),
            window_days: 90,
            gmv_cents: 400_000,
            views: 5_000,
            items_sold: 30,
            gpm_cents: 15_000,
            ctr: Decimal.new("3.4")
          }
        ])

      {:ok, view, _html} = live(conn, path)
      _ = render_async(view)

      assert has_element?(
               view,
               "#videos-grid .video-card:first-child .video-card__title",
               "All Time Leader"
             )

      view
      |> element("button[phx-value-preset='30']")
      |> render_click()

      assert_patch(view, "#{path}?period=30")
      _ = render_async(view)

      assert has_element?(
               view,
               "#videos-grid .video-card:first-child .video-card__title",
               "Period Leader"
             )

      assert has_element?(view, ".video-card__title", "All Time Leader")
    end

    test "invalid URL params default safely", %{conn: conn, path: path} do
      # Invalid period should default to "all"
      {:ok, view, _html} = live(conn, "#{path}?period=invalid")
      assert has_element?(view, "button.preset-filter__btn--active[phx-value-preset='all']")

      # Invalid sort should default to GMV
      {:ok, view2, _html} = live(conn, "#{path}?sort=invalid_sort")

      assert has_element?(
               view2,
               "#sort-filter .hover-dropdown__item--selected[phx-value-selection='gmv_desc']"
             )

      # Invalid min_gmv should default to $1K for non-GMV sort
      {:ok, view3, _html} = live(conn, "#{path}?sort=views_desc&min_gmv=12345")
      assert has_element?(view3, "button.preset-filter__btn--active[phx-value-amount='100000']")

      # Invalid min_gmv with trailing junk should also default to $1K
      {:ok, view4, _html} = live(conn, "#{path}?sort=views_desc&min_gmv=100000oops")
      assert has_element?(view4, "button.preset-filter__btn--active[phx-value-amount='100000']")
    end

    test "sort dropdown has simplified labels", %{conn: conn, path: path} do
      {:ok, _view, html} = live(conn, path)

      # Sort label and simplified option labels
      assert html =~ "Sort by:"
      assert html =~ "GMV"
      assert html =~ "GPM"
      assert html =~ "Views"
      assert html =~ "CTR"
      assert html =~ "Items Sold"
      assert html =~ "Newest First"
      assert html =~ "Oldest First"

      # Old "High to Low" labels should not appear
      refute html =~ "GMV: High to Low"
      refute html =~ "GMV: Low to High"
    end

    test "selecting sort option closes sort dropdown", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)

      refute has_element?(view, "#sort-filter.is-open")

      view
      |> element("#sort-filter > button[phx-click='toggle_sort_filter']")
      |> render_click()

      assert has_element?(view, "#sort-filter.is-open")

      select_sort(view, "views_desc")
      refute has_element?(view, "#sort-filter.is-open")
    end

    test "pagination respects active filters", %{
      conn: conn,
      path: path,
      brand: brand,
      creator: creator
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      videos =
        for i <- 6..35 do
          {:ok, video} =
            %Creators.CreatorVideo{
              brand_id: brand.id,
              creator_id: creator.id
            }
            |> Creators.CreatorVideo.changeset(%{
              tiktok_video_id: "video_#{i}",
              title: "Test Video #{i}",
              gmv_cents: i * 100_000,
              gpm_cents: i * 10_000,
              impressions: i * 1000,
              ctr: Decimal.new("#{i}.5"),
              items_sold: i * 10,
              posted_at: DateTime.add(now, -i, :day)
            })
            |> Repo.insert()

          video
        end

      insert_metric_snapshots(brand.id, videos)

      {:ok, view, _html} = live(conn, "#{path}?period=30&sort=views_desc")
      _ = render_async(view)
      assert has_element?(view, "button", "Load More Videos")

      view
      |> element("button", "Load More Videos")
      |> render_click()

      # Filter UI state remains active after loading next page
      assert has_element?(view, "button.preset-filter__btn--active[phx-value-preset='30']")

      assert has_element?(
               view,
               "#sort-filter .hover-dropdown__item--selected[phx-value-selection='views_desc']"
             )

      assert has_element?(view, "button.preset-filter__btn--active[phx-value-amount='100000']")
      # Old videos remain visible when period changes because period swaps metric source only.
      assert has_element?(view, ".video-card__title", "Test Video 5")
    end
  end

  describe "mobile toggle behavior" do
    setup %{conn: conn} do
      brand = brand_fixture()
      user = user_fixture()
      {:ok, _user_brand} = Accounts.create_user_brand(user, brand, :admin)

      conn = log_in_user(conn, user)
      path = "/b/#{brand.slug}/videos"

      %{conn: conn, brand: brand, path: path}
    end

    test "toggle_time_filter toggles is-open class", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)

      # Initially closed
      refute has_element?(view, ".preset-filter.is-open")

      # Click toggle
      view
      |> element("button[phx-click='toggle_time_filter']")
      |> render_click()

      # Should now have is-open class
      assert has_element?(view, ".preset-filter.is-open")

      # Click again to close
      view
      |> element("button[phx-click='toggle_time_filter']")
      |> render_click()

      refute has_element?(view, ".preset-filter.is-open")
    end

    test "toggle_min_gmv_filter toggles is-open class", %{conn: conn, path: path} do
      # Need non-GMV sort for min GMV filter to be visible
      {:ok, view, _html} = live(conn, "#{path}?sort=views_desc")

      # Click toggle
      view
      |> element("button[phx-click='toggle_min_gmv_filter']")
      |> render_click()

      # Should have is-open class on min GMV preset filter
      assert has_element?(view, ".preset-filter--min-gmv.is-open")
    end

    test "selecting time preset closes open filter", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)

      view
      |> element("button[phx-click='toggle_time_filter']")
      |> render_click()

      assert has_element?(view, ".preset-filter.is-open")

      view
      |> element("button[phx-value-preset='30']")
      |> render_click()

      refute has_element?(view, ".preset-filter.is-open")
    end

    test "selecting min GMV preset closes open filter", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, "#{path}?sort=views_desc")

      view
      |> element("button[phx-click='toggle_min_gmv_filter']")
      |> render_click()

      assert has_element?(view, ".preset-filter.is-open")

      view
      |> element("button[phx-value-amount='500000']")
      |> render_click()

      refute has_element?(view, ".preset-filter.is-open")
    end
  end

  defp select_sort(view, value) do
    view
    |> element("#sort-filter button[phx-value-selection='#{value}']")
    |> render_click()
  end

  defp insert_metric_snapshots(brand_id, videos) do
    snapshot_date = Date.utc_today()

    rows =
      for video <- videos, window_days <- [30, 90] do
        %{
          brand_id: brand_id,
          creator_video_id: video.id,
          tiktok_video_id: video.tiktok_video_id,
          snapshot_date: snapshot_date,
          window_days: window_days,
          gmv_cents: video.gmv_cents || 0,
          views: video.impressions || 0,
          items_sold: video.items_sold || 0,
          gpm_cents: video.gpm_cents,
          ctr: video.ctr
        }
      end

    _ = Creators.upsert_video_metric_snapshots(rows)
    :ok
  end
end
