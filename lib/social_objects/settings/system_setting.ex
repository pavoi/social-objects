defmodule SocialObjects.Settings.SystemSetting do
  @moduledoc """
  Schema for system-wide settings stored as key-value pairs.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          key: String.t() | nil,
          value: String.t() | nil,
          value_type: String.t(),
          brand_id: pos_integer() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  schema "system_settings" do
    field :key, :string
    field :value, :string
    field :value_type, :string, default: "string"

    belongs_to :brand, SocialObjects.Catalog.Brand

    timestamps()
  end

  @doc false
  def changeset(system_setting, attrs) do
    system_setting
    |> cast(attrs, [:key, :value, :value_type, :brand_id])
    |> validate_required([:key])
    |> unique_constraint([:brand_id, :key])
    |> unique_constraint([:key], name: :system_settings_global_key_unique)
    |> foreign_key_constraint(:brand_id)
  end
end
