defmodule SocialObjects.Catalog.Brand do
  @moduledoc """
  Represents a brand in the system.

  Brands own products and product sets. Each brand has a unique slug for URL routing.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          name: String.t() | nil,
          slug: String.t() | nil,
          notes: String.t() | nil,
          primary_domain: String.t() | nil,
          logo_url: String.t() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  schema "brands" do
    field :name, :string
    field :slug, :string
    field :notes, :string
    field :primary_domain, :string
    field :logo_url, :string

    has_many :products, SocialObjects.Catalog.Product
    has_many :product_sets, SocialObjects.ProductSets.ProductSet
    has_many :user_brands, SocialObjects.Accounts.UserBrand
    has_many :users, through: [:user_brands, :user]

    timestamps()
  end

  @doc false
  def changeset(brand, attrs) do
    brand
    |> cast(attrs, [:name, :slug, :notes, :primary_domain, :logo_url])
    |> validate_required([:name, :slug])
    |> unique_constraint(:name)
    |> unique_constraint(:slug)
    |> unique_constraint(:primary_domain)
  end
end
