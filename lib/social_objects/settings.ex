defmodule SocialObjects.Settings do
  @moduledoc """
  The Settings context for managing brand-scoped configuration.
  """

  import Ecto.Query, warn: false
  alias SocialObjects.Repo
  alias SocialObjects.Settings.SystemSetting

  @doc """
  Returns the configured application name.
  """
  def app_name do
    Application.get_env(:social_objects, :app_name, "App")
  end

  @doc """
  Returns the configured auth "from" name, falling back to app name.
  """
  def auth_from_name do
    env_or_default(:auth_from_name, app_name())
  end

  @doc """
  Returns the configured auth "from" email, falling back to noreply.
  """
  def auth_from_email do
    env_or_default(:auth_from_email, "noreply@example.com")
  end

  @doc """
  Gets the last Shopify sync timestamp.

  Returns nil if never synced or a DateTime if synced before.
  """
  def get_shopify_last_sync_at(brand_id) do
    get_datetime_setting(brand_id, "shopify_last_sync_at")
  end

  @doc """
  Updates the last Shopify sync timestamp to the current time.
  """
  def update_shopify_last_sync_at(brand_id) do
    upsert_setting(brand_id, "shopify_last_sync_at", now_iso(), "datetime")
  end

  @doc """
  Gets the last TikTok Shop sync timestamp.

  Returns nil if never synced or a DateTime if synced before.
  """
  def get_tiktok_last_sync_at(brand_id) do
    get_datetime_setting(brand_id, "tiktok_last_sync_at")
  end

  @doc """
  Updates the last TikTok Shop sync timestamp to the current time.
  """
  def update_tiktok_last_sync_at(brand_id) do
    upsert_setting(brand_id, "tiktok_last_sync_at", now_iso(), "datetime")
  end

  @doc """
  Gets the last TikTok Live scan timestamp.

  Returns nil if never scanned or a DateTime if scanned before.
  """
  def get_tiktok_live_last_scan_at(brand_id) do
    get_datetime_setting(brand_id, "tiktok_live_last_scan_at")
  end

  @doc """
  Updates the last TikTok Live scan timestamp to the current time.
  """
  def update_tiktok_live_last_scan_at(brand_id) do
    upsert_setting(brand_id, "tiktok_live_last_scan_at", now_iso(), "datetime")
  end

  @doc """
  Gets the last BigQuery orders sync timestamp.

  Returns nil if never synced or a DateTime if synced before.
  """
  def get_bigquery_last_sync_at(brand_id) do
    get_datetime_setting(brand_id, "bigquery_last_sync_at")
  end

  @doc """
  Updates the last BigQuery orders sync timestamp to the current time.
  """
  def update_bigquery_last_sync_at(brand_id) do
    upsert_setting(brand_id, "bigquery_last_sync_at", now_iso(), "datetime")
  end

  @doc """
  Gets the last creator enrichment sync timestamp.

  Returns nil if never synced or a DateTime if synced before.
  """
  def get_enrichment_last_sync_at(brand_id) do
    get_datetime_setting(brand_id, "enrichment_last_sync_at")
  end

  @doc """
  Updates the last creator enrichment sync timestamp to the current time.
  """
  def update_enrichment_last_sync_at(brand_id) do
    upsert_setting(brand_id, "enrichment_last_sync_at", now_iso(), "datetime")
  end

  @doc """
  Gets the last creator videos import timestamp.

  Returns nil if never imported or a DateTime if imported before.
  """
  def get_videos_last_import_at(brand_id) do
    get_datetime_setting(brand_id, "videos_last_import_at")
  end

  @doc """
  Updates the last creator videos import timestamp to the current time.
  """
  def update_videos_last_import_at(brand_id) do
    upsert_setting(brand_id, "videos_last_import_at", now_iso(), "datetime")
  end

  @doc """
  Gets the last product performance sync timestamp.

  Returns nil if never synced or a DateTime if synced before.
  """
  def get_product_performance_last_sync_at(brand_id) do
    get_datetime_setting(brand_id, "product_performance_last_sync_at")
  end

  @doc """
  Updates the last product performance sync timestamp to the current time.
  """
  def update_product_performance_last_sync_at(brand_id) do
    upsert_setting(brand_id, "product_performance_last_sync_at", now_iso(), "datetime")
  end

  @doc """
  Gets the last creator purchase sync timestamp.

  Returns nil if never synced or a DateTime if synced before.
  """
  def get_creator_purchase_last_sync_at(brand_id) do
    get_datetime_setting(brand_id, "creator_purchase_last_sync_at")
  end

  @doc """
  Updates the last creator purchase sync timestamp to the current time.
  """
  def update_creator_purchase_last_sync_at(brand_id) do
    upsert_setting(brand_id, "creator_purchase_last_sync_at", now_iso(), "datetime")
  end

  @doc """
  Gets the last stream analytics sync timestamp.

  Returns nil if never synced or a DateTime if synced before.
  """
  def get_stream_analytics_last_sync_at(brand_id) do
    get_datetime_setting(brand_id, "stream_analytics_last_sync_at")
  end

  @doc """
  Updates the last stream analytics sync timestamp to the current time.
  """
  def update_stream_analytics_last_sync_at(brand_id) do
    upsert_setting(brand_id, "stream_analytics_last_sync_at", now_iso(), "datetime")
  end

  @doc """
  Gets the last weekly recap sent timestamp.

  Returns nil if never sent or a DateTime if sent before.
  """
  def get_weekly_recap_last_sent_at(brand_id) do
    get_datetime_setting(brand_id, "weekly_recap_last_sent_at")
  end

  @doc """
  Updates the last weekly recap sent timestamp to the current time.
  """
  def update_weekly_recap_last_sent_at(brand_id) do
    upsert_setting(brand_id, "weekly_recap_last_sent_at", now_iso(), "datetime")
  end

  @doc """
  Gets a generic string setting by key.

  Returns nil if the setting doesn't exist.
  """
  def get_setting(brand_id, key) when is_binary(key) do
    case Repo.get_by(SystemSetting, brand_id: brand_id, key: key) do
      nil -> nil
      setting -> setting.value
    end
  end

  @doc """
  Sets a generic string setting.

  Creates the setting if it doesn't exist, updates it if it does.
  """
  def set_setting(brand_id, key, value) when is_binary(key) and is_binary(value) do
    upsert_setting(brand_id, key, value, "string")
  end

  @doc """
  Sets or clears a string setting.
  """
  def put_setting(brand_id, key, value) when is_binary(key) do
    case value do
      nil -> delete_setting(brand_id, key)
      "" -> delete_setting(brand_id, key)
      _ -> set_setting(brand_id, key, to_string(value))
    end
  end

  @doc """
  Deletes a setting.
  """
  def delete_setting(brand_id, key) when is_binary(key) do
    Repo.delete_all(from(s in SystemSetting, where: s.brand_id == ^brand_id and s.key == ^key))
    :ok
  end

  @doc """
  Returns the SendGrid from name for a brand, falling back to app config.
  """
  def get_sendgrid_from_name(brand_id) do
    get_setting_value(brand_id, "sendgrid_from_name") ||
      env_or_default(:sendgrid_from_name, app_name())
  end

  @doc """
  Returns the SendGrid from email for a brand, falling back to app config.
  """
  def get_sendgrid_from_email(brand_id) do
    get_setting_value(brand_id, "sendgrid_from_email") ||
      env_or_default(:sendgrid_from_email, "noreply@example.com")
  end

  defp env_or_default(key, default) do
    case Application.get_env(:social_objects, key) do
      value when value in [nil, ""] -> default
      value -> value
    end
  end

  @doc """
  Returns Slack bot token for a brand, falling back to app config.
  """
  def get_slack_bot_token(brand_id) do
    get_setting_value(brand_id, "slack_bot_token") ||
      Application.get_env(:social_objects, :slack_bot_token)
  end

  @doc """
  Returns Slack channel for a brand, falling back to app config.
  """
  def get_slack_channel(brand_id) do
    get_setting_value(brand_id, "slack_channel") ||
      Application.get_env(:social_objects, :slack_channel, "#tiktok-live-reports")
  end

  @doc """
  Returns Slack dev user id for a brand, falling back to app config.
  """
  def get_slack_dev_user_id(brand_id) do
    get_setting_value(brand_id, "slack_dev_user_id") ||
      Application.get_env(:social_objects, :slack_dev_user_id)
  end

  @doc """
  Returns Shopify store name for a brand, falling back to app config.
  """
  def get_shopify_store_name(brand_id) do
    get_setting_value(brand_id, "shopify_store_name") ||
      Application.get_env(:social_objects, :shopify_store_name)
  end

  @doc """
  Returns Shopify client id for a brand, falling back to app config.
  """
  def get_shopify_client_id(brand_id) do
    get_setting_value(brand_id, "shopify_client_id") ||
      Application.get_env(:social_objects, :shopify_client_id)
  end

  @doc """
  Returns Shopify client secret for a brand, falling back to app config.
  """
  def get_shopify_client_secret(brand_id) do
    get_setting_value(brand_id, "shopify_client_secret") ||
      Application.get_env(:social_objects, :shopify_client_secret)
  end

  @doc """
  Returns Shopify include tags for a brand.

  When set, only products with at least one of these tags will be synced.
  Returns an empty list if not configured (no filtering).
  """
  def get_shopify_include_tags(brand_id) do
    parse_csv_setting(get_setting(brand_id, "shopify_include_tags"))
  end

  @doc """
  Sets Shopify include tags for a brand.

  Accepts a list of tag strings or a comma-separated string.
  """
  def set_shopify_include_tags(brand_id, tags) do
    set_csv_setting(brand_id, "shopify_include_tags", tags)
  end

  @doc """
  Returns Shopify exclude tags for a brand.

  When set, products with any of these tags will be skipped during sync.
  Returns an empty list if not configured (no filtering).
  """
  def get_shopify_exclude_tags(brand_id) do
    parse_csv_setting(get_setting(brand_id, "shopify_exclude_tags"))
  end

  @doc """
  Sets Shopify exclude tags for a brand.

  Accepts a list of tag strings or a comma-separated string.
  """
  def set_shopify_exclude_tags(brand_id, tags) do
    set_csv_setting(brand_id, "shopify_exclude_tags", tags)
  end

  @doc """
  Returns BigQuery project id for a brand, falling back to app config.
  """
  def get_bigquery_project_id(brand_id) do
    get_setting_value(brand_id, "bigquery_project_id") ||
      Application.get_env(:social_objects, :bigquery_project_id)
  end

  @doc """
  Returns BigQuery dataset identifier for a brand.
  """
  def get_bigquery_dataset(brand_id) do
    get_setting_value(brand_id, "bigquery_dataset") ||
      Application.get_env(:social_objects, :bigquery_dataset)
  end

  @doc """
  Returns BigQuery service account email for a brand, falling back to app config.
  """
  def get_bigquery_service_account_email(brand_id) do
    get_setting_value(brand_id, "bigquery_service_account_email") ||
      Application.get_env(:social_objects, :bigquery_service_account_email)
  end

  @doc """
  Returns BigQuery private key for a brand, falling back to app config.
  """
  def get_bigquery_private_key(brand_id) do
    get_setting_value(brand_id, "bigquery_private_key") ||
      Application.get_env(:social_objects, :bigquery_private_key)
  end

  @doc """
  Returns the TikTok Live accounts to monitor for a brand.

  Falls back to application config if no setting exists.
  """
  def get_tiktok_live_accounts(brand_id) do
    case get_setting(brand_id, "tiktok_live_accounts") do
      nil ->
        Application.get_env(:social_objects, :tiktok_live_monitor, [])
        |> Keyword.get(:accounts, [])

      value ->
        value
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  @doc """
  Stores the TikTok Live accounts to monitor for a brand.
  """
  def set_tiktok_live_accounts(brand_id, accounts) when is_list(accounts) do
    accounts_string =
      accounts
      |> Enum.map(&String.trim(to_string(&1)))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(",")

    set_setting(brand_id, "tiktok_live_accounts", accounts_string)
  end

  # =============================================================================
  # Enrichment Rate Limit Tracking
  # =============================================================================

  @doc """
  Gets the last time enrichment was rate limited.
  Returns nil if never rate limited.
  """
  def get_enrichment_last_rate_limited_at(brand_id) do
    get_datetime_setting(brand_id, "enrichment_last_rate_limited_at")
  end

  @doc """
  Gets the current rate limit streak (consecutive rate limits).
  Returns 0 if no streak.
  """
  def get_enrichment_rate_limit_streak(brand_id) do
    case Repo.get_by(SystemSetting, brand_id: brand_id, key: "enrichment_rate_limit_streak") do
      nil -> 0
      setting -> String.to_integer(setting.value)
    end
  end

  @doc """
  Records a rate limit event. Increments the streak counter.
  """
  def record_enrichment_rate_limit(brand_id) do
    now = now_iso()
    streak = get_enrichment_rate_limit_streak(brand_id) + 1

    upsert_setting(brand_id, "enrichment_last_rate_limited_at", now, "datetime")
    upsert_setting(brand_id, "enrichment_rate_limit_streak", Integer.to_string(streak), "integer")

    streak
  end

  @doc """
  Resets the rate limit streak after a successful enrichment run.
  """
  def reset_enrichment_rate_limit_streak(brand_id) do
    upsert_setting(brand_id, "enrichment_rate_limit_streak", "0", "integer")
  end

  defp get_datetime_setting(brand_id, key) do
    case Repo.get_by(SystemSetting, brand_id: brand_id, key: key) do
      nil -> nil
      setting -> parse_datetime(setting.value)
    end
  end

  defp upsert_setting(brand_id, key, value, value_type) do
    case Repo.get_by(SystemSetting, brand_id: brand_id, key: key) do
      nil ->
        %SystemSetting{brand_id: brand_id}
        |> SystemSetting.changeset(%{key: key, value: value, value_type: value_type})
        |> Repo.insert()

      setting ->
        setting
        |> SystemSetting.changeset(%{value: value})
        |> Repo.update()
    end
  end

  defp get_setting_value(nil, _key), do: nil

  defp get_setting_value(brand_id, key) when is_binary(key) do
    case get_setting(brand_id, key) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  defp now_iso do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> nil
    end
  end

  defp parse_csv_setting(nil), do: []
  defp parse_csv_setting(""), do: []

  defp parse_csv_setting(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp set_csv_setting(brand_id, key, tags) when is_list(tags) do
    tags_string =
      tags
      |> Enum.map(&String.trim(to_string(&1)))
      |> Enum.map(&String.downcase/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(",")

    if tags_string == "" do
      delete_setting(brand_id, key)
    else
      set_setting(brand_id, key, tags_string)
    end
  end

  defp set_csv_setting(brand_id, key, tags) when is_binary(tags) do
    set_csv_setting(brand_id, key, String.split(tags, ","))
  end
end
