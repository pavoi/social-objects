defmodule Pavoi.Sessions.SessionProduct do
  @moduledoc """
  Represents a product featured in a live session with optional per-session overrides.

  Links products from the catalog to sessions and allows customization of name,
  pricing, and talking points specific to a session without modifying the base product.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "session_products" do
    field :position, :integer
    field :section, :string
    field :featured_name, :string
    field :featured_talking_points_md, :string
    field :featured_original_price_cents, :integer
    field :featured_sale_price_cents, :integer
    field :notes, :string

    belongs_to :session, Pavoi.Sessions.Session
    belongs_to :product, Pavoi.Catalog.Product

    timestamps()
  end

  @doc false
  def changeset(session_product, attrs) do
    session_product
    |> cast(attrs, [
      :session_id,
      :product_id,
      :position,
      :section,
      :featured_name,
      :featured_talking_points_md,
      :featured_original_price_cents,
      :featured_sale_price_cents,
      :notes
    ])
    |> validate_required([:session_id, :product_id, :position])
    |> validate_number(:position, greater_than: 0)
    |> unique_constraint([:session_id, :position])
    |> unique_constraint([:session_id, :product_id])
    |> foreign_key_constraint(:session_id)
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
  def effective_prices(%__MODULE__{} = sp) do
    %{
      original: sp.featured_original_price_cents || sp.product.original_price_cents,
      sale: sp.featured_sale_price_cents || sp.product.sale_price_cents
    }
  end
end
