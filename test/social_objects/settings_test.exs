defmodule SocialObjects.SettingsTest do
  use SocialObjects.DataCase, async: false

  alias SocialObjects.Catalog
  alias SocialObjects.Settings

  @env_keys [
    :shopify_store_name,
    :shopify_client_id,
    :shopify_client_secret,
    :bigquery_project_id,
    :bigquery_dataset,
    :bigquery_service_account_email,
    :bigquery_private_key,
    :tiktok_live_monitor
  ]

  setup do
    previous_env =
      Map.new(@env_keys, fn key ->
        {key, Application.get_env(:social_objects, key)}
      end)

    on_exit(fn ->
      Enum.each(previous_env, fn {key, value} ->
        if is_nil(value) do
          Application.delete_env(:social_objects, key)
        else
          Application.put_env(:social_objects, key, value)
        end
      end)
    end)

    :ok
  end

  test "shopify settings are brand-scoped and do not fall back to env defaults" do
    Application.put_env(:social_objects, :shopify_store_name, "env-store")
    Application.put_env(:social_objects, :shopify_client_id, "env-client-id")
    Application.put_env(:social_objects, :shopify_client_secret, "env-client-secret")

    brand_a = catalog_brand_fixture()
    brand_b = catalog_brand_fixture()

    assert Settings.get_shopify_store_name(brand_a.id) == nil
    assert Settings.get_shopify_client_id(brand_a.id) == nil
    assert Settings.get_shopify_client_secret(brand_a.id) == nil
    refute Settings.shopify_configured?(brand_a.id)

    Settings.put_setting(brand_a.id, "shopify_store_name", "brand-a-store")
    Settings.put_setting(brand_a.id, "shopify_client_id", "brand-a-client-id")
    Settings.put_setting(brand_a.id, "shopify_client_secret", "brand-a-client-secret")

    assert Settings.get_shopify_store_name(brand_a.id) == "brand-a-store"
    assert Settings.get_shopify_client_id(brand_a.id) == "brand-a-client-id"
    assert Settings.get_shopify_client_secret(brand_a.id) == "brand-a-client-secret"
    assert Settings.shopify_configured?(brand_a.id)

    assert Settings.get_shopify_store_name(brand_b.id) == nil
    assert Settings.get_shopify_client_id(brand_b.id) == nil
    assert Settings.get_shopify_client_secret(brand_b.id) == nil
    refute Settings.shopify_configured?(brand_b.id)
  end

  test "bigquery settings are brand-scoped and do not fall back to env defaults" do
    Application.put_env(:social_objects, :bigquery_project_id, "env-project")
    Application.put_env(:social_objects, :bigquery_dataset, "env-dataset")
    Application.put_env(:social_objects, :bigquery_service_account_email, "env@example.com")
    Application.put_env(:social_objects, :bigquery_private_key, "env-private-key")

    brand = catalog_brand_fixture()

    assert Settings.get_bigquery_project_id(brand.id) == nil
    assert Settings.get_bigquery_dataset(brand.id) == nil
    assert Settings.get_bigquery_service_account_email(brand.id) == nil
    assert Settings.get_bigquery_private_key(brand.id) == nil
    refute Settings.bigquery_configured?(brand.id)

    Settings.put_setting(brand.id, "bigquery_project_id", "brand-project")
    Settings.put_setting(brand.id, "bigquery_dataset", "brand_dataset")
    Settings.put_setting(brand.id, "bigquery_service_account_email", "brand@example.com")
    Settings.put_setting(brand.id, "bigquery_private_key", "brand-private-key")

    assert Settings.get_bigquery_project_id(brand.id) == "brand-project"
    assert Settings.get_bigquery_dataset(brand.id) == "brand_dataset"
    assert Settings.get_bigquery_service_account_email(brand.id) == "brand@example.com"
    assert Settings.get_bigquery_private_key(brand.id) == "brand-private-key"
    assert Settings.bigquery_configured?(brand.id)
  end

  test "tiktok live accounts are empty for unconfigured brands" do
    Application.put_env(:social_objects, :tiktok_live_monitor, accounts: ["env_account"])

    brand = catalog_brand_fixture()

    assert Settings.get_tiktok_live_accounts(brand.id) == []
    assert Settings.get_tiktok_live_accounts(nil) == ["env_account"]

    Settings.put_setting(brand.id, "tiktok_live_accounts", "alpha, beta")

    assert Settings.get_tiktok_live_accounts(brand.id) == ["alpha", "beta"]
  end

  test "vip cycle started_at is stored per brand" do
    brand_a = catalog_brand_fixture()
    brand_b = catalog_brand_fixture()

    assert is_nil(Settings.get_vip_cycle_started_at(brand_a.id))
    assert is_nil(Settings.get_vip_cycle_started_at(brand_b.id))

    assert {:ok, _} = Settings.update_vip_cycle_started_at(brand_a.id, ~D[2026-01-01])
    assert Settings.get_vip_cycle_started_at(brand_a.id) == ~D[2026-01-01]
    assert is_nil(Settings.get_vip_cycle_started_at(brand_b.id))
  end

  defp catalog_brand_fixture do
    unique = System.unique_integer([:positive])

    {:ok, brand} =
      Catalog.create_brand(%{
        name: "Brand #{unique}",
        slug: "brand-#{unique}"
      })

    brand
  end
end
