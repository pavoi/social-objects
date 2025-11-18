defmodule Pavoi.Catalog.Brand do
  @moduledoc """
  Represents a brand in the system.

  Brands own products and sessions. Each brand has a unique slug for URL routing.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "brands" do
    field :name, :string
    field :slug, :string
    field :notes, :string

    has_many :products, Pavoi.Catalog.Product
    has_many :sessions, Pavoi.Sessions.Session

    timestamps()
  end

  @doc false
  def changeset(brand, attrs) do
    brand
    |> cast(attrs, [:name, :slug, :notes])
    |> validate_required([:name, :slug])
    |> unique_constraint(:name)
    |> unique_constraint(:slug)
  end
end
