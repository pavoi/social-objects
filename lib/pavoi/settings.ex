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

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> nil
    end
  end
end
