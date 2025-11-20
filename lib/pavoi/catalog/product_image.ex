defmodule Pavoi.Catalog.ProductImage do
  @moduledoc """
  Represents an image associated with a product.

  Products can have multiple images in a specific order. Image URLs are
  provided by Shopify and stored directly in the database.

  Fields:
  - `path` - Full Shopify image URL
  - `thumbnail_path` - Optional thumbnail or variant URL (Shopify supports URL-based transformations)
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "product_images" do
    field :position, :integer, default: 0
    field :path, :string
    field :thumbnail_path, :string
    field :alt_text, :string
    field :is_primary, :boolean, default: false
    field :tiktok_uri, :string

    belongs_to :product, Pavoi.Catalog.Product

    timestamps()
  end

  @doc false
  def changeset(image, attrs) do
    image
    |> cast(attrs, [:product_id, :position, :path, :thumbnail_path, :alt_text, :is_primary, :tiktok_uri])
    |> validate_required([:product_id, :path])
    |> foreign_key_constraint(:product_id)
  end
end
