defmodule SocialObjects.CreatorPerformanceSnapshotTest do
  use SocialObjects.DataCase, async: true

  alias SocialObjects.Creators
  alias SocialObjects.Creators.CreatorPerformanceSnapshot

  test "snapshot uniqueness is scoped by brand_id" do
    brand_a = brand_fixture()
    brand_b = brand_fixture()

    {:ok, creator} =
      Creators.create_creator(%{
        tiktok_username: "snapshot-user-#{System.unique_integer([:positive])}"
      })

    attrs = %{
      creator_id: creator.id,
      snapshot_date: ~D[2026-02-20],
      source: "brand_gmv",
      gmv_cents: 100_000
    }

    assert {:ok, _snapshot_a} =
             %CreatorPerformanceSnapshot{brand_id: brand_a.id}
             |> CreatorPerformanceSnapshot.changeset(attrs)
             |> Repo.insert()

    assert {:ok, _snapshot_b} =
             %CreatorPerformanceSnapshot{brand_id: brand_b.id}
             |> CreatorPerformanceSnapshot.changeset(attrs)
             |> Repo.insert()

    assert {:error, changeset} =
             %CreatorPerformanceSnapshot{brand_id: brand_a.id}
             |> CreatorPerformanceSnapshot.changeset(attrs)
             |> Repo.insert()

    assert errors_on(changeset)
           |> Map.values()
           |> List.flatten()
           |> Enum.any?(&(&1 == "has already been taken"))
  end
end
