defmodule SocialObjects.Accounts.UserBrand do
  @moduledoc """
  Represents a user's access to a brand with a specific role.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type role :: :owner | :admin | :viewer

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          user_id: pos_integer() | nil,
          brand_id: pos_integer() | nil,
          role: role(),
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  @roles ~w(owner admin viewer)a

  schema "user_brands" do
    belongs_to :user, SocialObjects.Accounts.User
    belongs_to :brand, SocialObjects.Catalog.Brand
    field :role, Ecto.Enum, values: @roles, default: :viewer

    timestamps()
  end

  @doc """
  Returns the list of valid roles.
  """
  def roles, do: @roles

  @doc false
  def changeset(user_brand, attrs) do
    user_brand
    |> cast(attrs, [:role])
    |> validate_required([:role])
  end
end
