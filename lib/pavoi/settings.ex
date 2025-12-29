defmodule Pavoi.Settings do
  @moduledoc """
  The Settings context for managing system-wide configuration.
  """

  import Ecto.Query, warn: false
  alias Pavoi.Repo
  alias Pavoi.Settings.SystemSetting

  @doc """
  Gets the last Shopify sync timestamp.

  Returns nil if never synced or a DateTime if synced before.
  """
  def get_shopify_last_sync_at do
    case Repo.get_by(SystemSetting, key: "shopify_last_sync_at") do
      nil -> nil
      setting -> parse_datetime(setting.value)
    end
  end

  @doc """
  Updates the last Shopify sync timestamp to the current time.
  """
  def update_shopify_last_sync_at do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    case Repo.get_by(SystemSetting, key: "shopify_last_sync_at") do
      nil ->
        %SystemSetting{}
        |> SystemSetting.changeset(%{
          key: "shopify_last_sync_at",
          value: now,
          value_type: "datetime"
        })
        |> Repo.insert()

      setting ->
        setting
        |> SystemSetting.changeset(%{value: now})
        |> Repo.update()
    end
  end

  @doc """
  Gets the last TikTok Shop sync timestamp.

  Returns nil if never synced or a DateTime if synced before.
  """
  def get_tiktok_last_sync_at do
    case Repo.get_by(SystemSetting, key: "tiktok_last_sync_at") do
      nil -> nil
      setting -> parse_datetime(setting.value)
    end
  end

  @doc """
  Updates the last TikTok Shop sync timestamp to the current time.
  """
  def update_tiktok_last_sync_at do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    case Repo.get_by(SystemSetting, key: "tiktok_last_sync_at") do
      nil ->
        %SystemSetting{}
        |> SystemSetting.changeset(%{
          key: "tiktok_last_sync_at",
          value: now,
          value_type: "datetime"
        })
        |> Repo.insert()

      setting ->
        setting
        |> SystemSetting.changeset(%{value: now})
        |> Repo.update()
    end
  end

  @doc """
  Gets the last TikTok Live scan timestamp.

  Returns nil if never scanned or a DateTime if scanned before.
  """
  def get_tiktok_live_last_scan_at do
    case Repo.get_by(SystemSetting, key: "tiktok_live_last_scan_at") do
      nil -> nil
      setting -> parse_datetime(setting.value)
    end
  end

  @doc """
  Updates the last TikTok Live scan timestamp to the current time.
  """
  def update_tiktok_live_last_scan_at do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    case Repo.get_by(SystemSetting, key: "tiktok_live_last_scan_at") do
      nil ->
        %SystemSetting{}
        |> SystemSetting.changeset(%{
          key: "tiktok_live_last_scan_at",
          value: now,
          value_type: "datetime"
        })
        |> Repo.insert()

      setting ->
        setting
        |> SystemSetting.changeset(%{value: now})
        |> Repo.update()
    end
  end

  @doc """
  Gets the last BigQuery orders sync timestamp.

  Returns nil if never synced or a DateTime if synced before.
  """
  def get_bigquery_last_sync_at do
    case Repo.get_by(SystemSetting, key: "bigquery_last_sync_at") do
      nil -> nil
      setting -> parse_datetime(setting.value)
    end
  end

  @doc """
  Updates the last BigQuery orders sync timestamp to the current time.
  """
  def update_bigquery_last_sync_at do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    case Repo.get_by(SystemSetting, key: "bigquery_last_sync_at") do
      nil ->
        %SystemSetting{}
        |> SystemSetting.changeset(%{
          key: "bigquery_last_sync_at",
          value: now,
          value_type: "datetime"
        })
        |> Repo.insert()

      setting ->
        setting
        |> SystemSetting.changeset(%{value: now})
        |> Repo.update()
    end
  end

  @doc """
  Gets the last creator enrichment sync timestamp.

  Returns nil if never synced or a DateTime if synced before.
  """
  def get_enrichment_last_sync_at do
    case Repo.get_by(SystemSetting, key: "enrichment_last_sync_at") do
      nil -> nil
      setting -> parse_datetime(setting.value)
    end
  end

  @doc """
  Updates the last creator enrichment sync timestamp to the current time.
  """
  def update_enrichment_last_sync_at do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    case Repo.get_by(SystemSetting, key: "enrichment_last_sync_at") do
      nil ->
        %SystemSetting{}
        |> SystemSetting.changeset(%{
          key: "enrichment_last_sync_at",
          value: now,
          value_type: "datetime"
        })
        |> Repo.insert()

      setting ->
        setting
        |> SystemSetting.changeset(%{value: now})
        |> Repo.update()
    end
  end

  @doc """
  Gets the last creator videos import timestamp.

  Returns nil if never imported or a DateTime if imported before.
  """
  def get_videos_last_import_at do
    case Repo.get_by(SystemSetting, key: "videos_last_import_at") do
      nil -> nil
      setting -> parse_datetime(setting.value)
    end
  end

  @doc """
  Updates the last creator videos import timestamp to the current time.
  """
  def update_videos_last_import_at do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    case Repo.get_by(SystemSetting, key: "videos_last_import_at") do
      nil ->
        %SystemSetting{}
        |> SystemSetting.changeset(%{
          key: "videos_last_import_at",
          value: now,
          value_type: "datetime"
        })
        |> Repo.insert()

      setting ->
        setting
        |> SystemSetting.changeset(%{value: now})
        |> Repo.update()
    end
  end

  @doc """
  Gets a generic string setting by key.

  Returns nil if the setting doesn't exist.
  """
  def get_setting(key) when is_binary(key) do
    case Repo.get_by(SystemSetting, key: key) do
      nil -> nil
      setting -> setting.value
    end
  end

  @doc """
  Sets a generic string setting.

  Creates the setting if it doesn't exist, updates it if it does.
  """
  def set_setting(key, value) when is_binary(key) and is_binary(value) do
    case Repo.get_by(SystemSetting, key: key) do
      nil ->
        %SystemSetting{}
        |> SystemSetting.changeset(%{
          key: key,
          value: value,
          value_type: "string"
        })
        |> Repo.insert()

      setting ->
        setting
        |> SystemSetting.changeset(%{value: value})
        |> Repo.update()
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> nil
    end
  end
end
