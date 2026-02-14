defmodule SocialObjects.ProductSets.MessagePreset do
  @moduledoc """
  Represents a preset message template that can be sent to the host.

  Presets are global and can be used across all product sets. Each preset includes
  a label, message text, and color for visual styling on the host view.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type message_color :: :amber | :blue | :green | :red | :purple | :gray

  @type t :: %__MODULE__{
          id: binary() | nil,
          message_text: String.t() | nil,
          color: message_color() | nil,
          position: integer() | nil,
          brand_id: pos_integer() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_colors ~w(amber blue green red purple gray)a

  schema "message_presets" do
    field :message_text, :string
    field :color, Ecto.Enum, values: @valid_colors
    field :position, :integer

    belongs_to :brand, SocialObjects.Catalog.Brand, type: :id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Returns the list of valid color options.
  """
  def valid_colors, do: @valid_colors

  @doc false
  def changeset(message_preset, attrs) do
    message_preset
    |> cast(attrs, [:message_text, :color, :position])
    |> validate_required([:brand_id, :message_text, :color])
    |> validate_length(:message_text, min: 1, max: 1000)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:brand_id)
  end
end
