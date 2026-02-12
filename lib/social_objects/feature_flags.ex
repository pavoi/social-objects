defmodule SocialObjects.FeatureFlags do
  @moduledoc """
  Feature flags for controlling app-wide feature visibility.
  Stored as global settings (brand_id = NULL) with value_type = "boolean".
  """

  import Ecto.Query
  alias SocialObjects.Repo
  alias SocialObjects.Settings.SystemSetting

  # Known feature flags with defaults (true = visible)
  @flags %{
    "show_videos_nav" => true,
    "show_analytics_nav" => true,
    "voice_control" => true,
    "outreach_email" => true
  }

  @doc "Returns true if a feature flag is enabled."
  def enabled?(flag_name) when is_binary(flag_name) do
    case get_flag(flag_name) do
      nil -> Map.get(@flags, flag_name, false)
      value -> value
    end
  end

  @doc "Gets a feature flag value from the database."
  def get_flag(flag_name) do
    query =
      from(s in SystemSetting,
        where: is_nil(s.brand_id) and s.key == ^flag_name
      )

    case Repo.one(query) do
      nil -> nil
      setting -> parse_boolean(setting.value)
    end
  end

  @topic "feature_flags"

  @doc "Sets a feature flag value."
  def set_flag(flag_name, value) when is_boolean(value) do
    value_string = to_string(value)

    query =
      from(s in SystemSetting,
        where: is_nil(s.brand_id) and s.key == ^flag_name
      )

    result =
      case Repo.one(query) do
        nil ->
          %SystemSetting{brand_id: nil}
          |> SystemSetting.changeset(%{
            key: flag_name,
            value: value_string,
            value_type: "boolean"
          })
          |> Repo.insert()

        setting ->
          setting
          |> SystemSetting.changeset(%{value: value_string})
          |> Repo.update()
      end

    case result do
      {:ok, _} -> broadcast_change()
      _ -> :ok
    end

    result
  end

  @doc "Subscribe to feature flag changes."
  def subscribe do
    Phoenix.PubSub.subscribe(SocialObjects.PubSub, @topic)
  end

  defp broadcast_change do
    Phoenix.PubSub.broadcast(SocialObjects.PubSub, @topic, :feature_flags_changed)
  end

  @doc "Returns all feature flags with current values (DB merged with defaults)."
  def list_all do
    db_flags =
      from(s in SystemSetting,
        where: is_nil(s.brand_id) and s.value_type == "boolean",
        select: {s.key, s.value}
      )
      |> Repo.all()
      |> Map.new(fn {k, v} -> {k, parse_boolean(v)} end)

    Map.merge(@flags, db_flags)
  end

  @doc "Returns defined flags with labels for UI."
  def defined_flags do
    [
      %{
        key: "show_videos_nav",
        label: "Videos",
        description: "Show Videos in navigation and readme"
      },
      %{
        key: "show_analytics_nav",
        label: "Analytics",
        description: "Show Analytics in navigation"
      },
      %{
        key: "voice_control",
        label: "Voice Control",
        description: "Enable voice commands in the product controller"
      },
      %{
        key: "outreach_email",
        label: "Outreach Email",
        description: "Enable sending outreach emails to creators"
      }
    ]
  end

  defp parse_boolean("true"), do: true
  defp parse_boolean(_), do: false
end
