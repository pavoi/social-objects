defmodule Pavoi.Catalog.Product do
  @moduledoc """
  Represents a product in the catalog.

  Products belong to brands and contain details like name, pricing, descriptions,
  talking points, and associated images. Products can be featured in live sessions.

  ## Field Ownership

  Product fields fall into two categories:

  - **Shopify-synced fields**: Automatically synced from Shopify API every 24 hours.
    These fields are read-only and should not be edited by users, as edits will be
    overwritten on the next sync.

  - **User-editable fields**: Managed exclusively by users and never overwritten by
    Shopify sync. These include manually-entered content and AI-generated content.
  """
  use Ecto.Schema
  import Ecto.Changeset

  # Fields that are synced from Shopify API and will be overwritten on sync
  @shopify_synced_fields [
    :brand_id,
    :name,
    :description,
    :original_price_cents,
    :sale_price_cents,
    :pid,
    :sku
  ]

  # Fields that are editable by users and never synced from Shopify
  @user_editable_fields [
    :talking_points_md
  ]

  schema "products" do
    field :name, :string
    field :description, :string
    field :talking_points_md, :string
    field :original_price_cents, :integer
    field :sale_price_cents, :integer
    field :pid, :string
    field :sku, :string

    belongs_to :brand, Pavoi.Catalog.Brand
    has_many :product_images, Pavoi.Catalog.ProductImage, preload_order: [asc: :position]
    has_many :product_variants, Pavoi.Catalog.ProductVariant, preload_order: [asc: :position]
    has_many :session_products, Pavoi.Sessions.SessionProduct

    timestamps()
  end

  @doc false
  def changeset(product, attrs) do
    product
    |> cast(attrs, [
      :brand_id,
      :name,
      :description,
      :talking_points_md,
      :original_price_cents,
      :sale_price_cents,
      :pid,
      :sku
    ])
    |> validate_required([:brand_id, :name, :original_price_cents])
    |> validate_number(:original_price_cents, greater_than: 0)
    |> validate_sale_price()
    |> unique_constraint(:pid)
    |> foreign_key_constraint(:brand_id)
  end

  defp validate_sale_price(changeset) do
    case get_field(changeset, :sale_price_cents) do
      nil -> changeset
      price when price > 0 -> changeset
      _ -> add_error(changeset, :sale_price_cents, "must be nil or greater than 0")
    end
  end

  @doc """
  Returns the list of fields that are synced from Shopify API.

  These fields are read-only and will be overwritten on the next sync.
  """
  def shopify_synced_fields, do: @shopify_synced_fields

  @doc """
  Returns the list of fields that are editable by users.

  These fields are never overwritten by Shopify sync.
  """
  def user_editable_fields, do: @user_editable_fields

  @doc """
  Returns true if the given field is editable by users, false otherwise.

  ## Examples

      iex> Product.field_editable?(:talking_points_md)
      true

      iex> Product.field_editable?(:name)
      false
  """
  def field_editable?(field) when is_atom(field) do
    field in @user_editable_fields
  end

  def field_editable?(field) when is_binary(field) do
    field_atom = String.to_existing_atom(field)
    field_editable?(field_atom)
  rescue
    ArgumentError -> false
  end
end
