defmodule Pavoi.Settings.SystemSetting do
  @moduledoc """
  Schema for system-wide settings stored as key-value pairs.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "system_settings" do
    field :key, :string
    field :value, :string
    field :value_type, :string, default: "string"

    timestamps()
  end

  @doc false
  def changeset(system_setting, attrs) do
    system_setting
    |> cast(attrs, [:key, :value, :value_type])
    |> validate_required([:key])
    |> unique_constraint(:key)
  end
end
