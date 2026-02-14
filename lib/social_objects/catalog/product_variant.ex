defmodule SocialObjects.Catalog.ProductVariant do
  @moduledoc """
  Represents a product variant (e.g., different colors, sizes, or option combinations).

  Variants are synced from Shopify and contain pricing, SKU, and option data.
  Each product can have multiple variants representing different configurations.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          shopify_variant_id: String.t() | nil,
          title: String.t() | nil,
          sku: String.t() | nil,
          price_cents: integer() | nil,
          compare_at_price_cents: integer() | nil,
          barcode: String.t() | nil,
          position: integer() | nil,
          selected_options: map() | nil,
          tiktok_sku_id: String.t() | nil,
          tiktok_price_cents: integer() | nil,
          tiktok_compare_at_price_cents: integer() | nil,
          size: String.t() | nil,
          size_type: String.t() | nil,
          size_source: String.t() | nil,
          product_id: pos_integer() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  schema "product_variants" do
    field :shopify_variant_id, :string
    field :title, :string
    field :sku, :string
    field :price_cents, :integer
    field :compare_at_price_cents, :integer
    field :barcode, :string
    field :position, :integer
    field :selected_options, :map
    field :tiktok_sku_id, :string
    field :tiktok_price_cents, :integer
    field :tiktok_compare_at_price_cents, :integer
    # Normalized size fields
    field :size, :string
    field :size_type, :string
    field :size_source, :string

    belongs_to :product, SocialObjects.Catalog.Product

    timestamps()
  end

  @doc false
  def changeset(product_variant, attrs) do
    product_variant
    |> cast(attrs, [
      :product_id,
      :shopify_variant_id,
      :title,
      :sku,
      :price_cents,
      :compare_at_price_cents,
      :barcode,
      :position,
      :selected_options,
      :tiktok_sku_id,
      :tiktok_price_cents,
      :tiktok_compare_at_price_cents,
      :size,
      :size_type,
      :size_source
    ])
    |> validate_required([:product_id, :title, :price_cents, :position])
    |> validate_number(:price_cents, greater_than: 0)
    |> validate_compare_at_price()
    |> validate_tiktok_compare_at_price()
    |> unique_constraint(:shopify_variant_id)
    |> unique_constraint(:tiktok_sku_id)
    |> foreign_key_constraint(:product_id)
  end

  defp validate_compare_at_price(changeset) do
    case get_field(changeset, :compare_at_price_cents) do
      nil -> changeset
      price when price > 0 -> changeset
      _ -> add_error(changeset, :compare_at_price_cents, "must be nil or greater than 0")
    end
  end

  defp validate_tiktok_compare_at_price(changeset) do
    case get_field(changeset, :tiktok_compare_at_price_cents) do
      nil -> changeset
      price when price > 0 -> changeset
      _ -> add_error(changeset, :tiktok_compare_at_price_cents, "must be nil or greater than 0")
    end
  end

  @doc """
  Formats selected_options map as a readable string.

  ## Examples

      iex> format_options(%{"Color" => "Yellow Gold", "Size" => "7"})
      "Color: Yellow Gold, Size: 7"

      iex> format_options(%{})
      ""
  """
  def format_options(options) when is_map(options) do
    options
    |> Enum.map_join(", ", fn {name, value} -> "#{name}: #{value}" end)
  end

  def format_options(_), do: ""
end
