defmodule SocialObjects.Creators.CreatorTag do
  @moduledoc """
  Represents a tag definition that can be applied to creators.

  Tags are scoped to brands - each brand has its own set of tag definitions
  with customizable names and colors.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: binary() | nil,
          name: String.t() | nil,
          color: String.t(),
          position: integer(),
          brand_id: pos_integer() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_colors ~w(amber blue green red purple gray)

  schema "creator_tags" do
    field :name, :string
    field :color, :string, default: "gray"
    field :position, :integer, default: 0

    belongs_to :brand, SocialObjects.Catalog.Brand, type: :id

    has_many :tag_assignments, SocialObjects.Creators.CreatorTagAssignment

    many_to_many :creators, SocialObjects.Creators.Creator,
      join_through: "creator_tag_assignments"

    timestamps(type: :utc_datetime)
  end

  @doc """
  Returns the list of valid color options.
  """
  def valid_colors, do: @valid_colors

  @doc false
  def changeset(tag, attrs) do
    tag
    |> cast(attrs, [:name, :color, :position, :brand_id])
    |> validate_required([:name, :brand_id])
    |> validate_length(:name, min: 1, max: 20)
    |> validate_inclusion(:color, @valid_colors)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint([:brand_id, :name], message: "tag already exists for this brand")
    |> foreign_key_constraint(:brand_id)
  end
end
