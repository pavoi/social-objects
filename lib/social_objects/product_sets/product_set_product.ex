defmodule SocialObjects.ProductSets.ProductSetProduct do
  @moduledoc """
  Represents a product featured in a product set with optional per-set overrides.

  Links products from the catalog to product sets and allows customization of name,
  pricing, and talking points specific to a product set without modifying the base product.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          position: integer() | nil,
          section: String.t() | nil,
          featured_name: String.t() | nil,
          featured_talking_points_md: String.t() | nil,
          featured_original_price_cents: integer() | nil,
          featured_sale_price_cents: integer() | nil,
          notes: String.t() | nil,
          product_set_id: pos_integer() | nil,
          product_id: pos_integer() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  schema "product_set_products" do
    field :position, :integer
    field :section, :string
    field :featured_name, :string
    field :featured_talking_points_md, :string
    field :featured_original_price_cents, :integer
    field :featured_sale_price_cents, :integer
    field :notes, :string

    belongs_to :product_set, SocialObjects.ProductSets.ProductSet
    belongs_to :product, SocialObjects.Catalog.Product

    timestamps()
  end

  @doc false
  def changeset(product_set_product, attrs) do
    product_set_product
    |> cast(attrs, [
      :product_set_id,
      :product_id,
      :position,
      :section,
      :featured_name,
      :featured_talking_points_md,
      :featured_original_price_cents,
      :featured_sale_price_cents,
      :notes
    ])
    |> validate_required([:product_set_id, :product_id, :position])
    |> validate_number(:position, greater_than: 0)
    |> unique_constraint([:product_set_id, :position])
    |> unique_constraint([:product_set_id, :product_id])
    |> foreign_key_constraint(:product_set_id)
    |> foreign_key_constraint(:product_id)
  end

  @doc """
  Returns the effective name (featured override or original product name).
  """
  def effective_name(%__MODULE__{featured_name: nil, product: %{name: name}}), do: name
  def effective_name(%__MODULE__{featured_name: name}) when is_binary(name), do: name
  def effective_name(%__MODULE__{featured_name: name}), do: name

  @doc """
  Returns the effective talking points (featured override or original).
  """
  def effective_talking_points(%__MODULE__{
        featured_talking_points_md: nil,
        product: %{talking_points_md: points}
      }),
      do: points

  def effective_talking_points(%__MODULE__{featured_talking_points_md: points})
      when is_binary(points),
      do: points

  def effective_talking_points(%__MODULE__{featured_talking_points_md: points}), do: points

  @doc """
  Returns the effective prices (featured overrides or original product prices).
  """
  def effective_prices(%__MODULE__{} = psp) do
    %{
      original: psp.featured_original_price_cents || psp.product.original_price_cents,
      sale: psp.featured_sale_price_cents || psp.product.sale_price_cents
    }
  end
end
