defmodule SocialObjects.Catalog.Product do
  @moduledoc """
  Represents a product in the catalog.

  Products belong to brands and contain details like name, pricing, descriptions,
  talking points, and associated images. Products can be featured in product sets.

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

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          talking_points_md: String.t() | nil,
          original_price_cents: integer() | nil,
          sale_price_cents: integer() | nil,
          pid: String.t() | nil,
          sku: String.t() | nil,
          tiktok_product_id: String.t() | nil,
          tiktok_product_ids: [String.t()],
          size_range: String.t() | nil,
          has_size_variants: boolean(),
          archived_at: DateTime.t() | nil,
          archive_reason: String.t() | nil,
          gmv_cents: integer(),
          items_sold: integer(),
          orders: integer(),
          performance_synced_at: DateTime.t() | nil,
          sample_count: integer(),
          sample_count_synced_at: DateTime.t() | nil,
          brand_id: pos_integer() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

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
    field :tiktok_product_id, :string
    field :tiktok_product_ids, {:array, :string}, default: []
    # Size fields (computed from variants)
    field :size_range, :string
    field :has_size_variants, :boolean, default: false

    # Archive fields (soft delete)
    field :archived_at, :utc_datetime
    field :archive_reason, :string

    # TikTok performance metrics (from Analytics API)
    field :gmv_cents, :integer, default: 0
    field :items_sold, :integer, default: 0
    field :orders, :integer, default: 0
    field :performance_synced_at, :utc_datetime

    # Sample tracking (from creator_samples)
    field :sample_count, :integer, default: 0
    field :sample_count_synced_at, :utc_datetime

    belongs_to :brand, SocialObjects.Catalog.Brand
    has_many :product_images, SocialObjects.Catalog.ProductImage, preload_order: [asc: :position]

    has_many :product_variants, SocialObjects.Catalog.ProductVariant,
      preload_order: [asc: :position]

    has_many :product_set_products, SocialObjects.ProductSets.ProductSetProduct

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
      :sku,
      :tiktok_product_id,
      :tiktok_product_ids,
      :size_range,
      :has_size_variants,
      :archived_at,
      :archive_reason
    ])
    |> validate_required([:brand_id, :name, :original_price_cents])
    |> validate_number(:original_price_cents, greater_than: 0)
    |> validate_sale_price()
    |> validate_archive_reason()
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

  @valid_archive_reasons ~w(shopify_filter_excluded manual)

  defp validate_archive_reason(changeset) do
    case get_field(changeset, :archive_reason) do
      nil ->
        changeset

      reason when reason in @valid_archive_reasons ->
        changeset

      _ ->
        add_error(
          changeset,
          :archive_reason,
          "must be one of: #{Enum.join(@valid_archive_reasons, ", ")}"
        )
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

  @doc """
  Returns true if the product is archived.

  ## Examples

      iex> Product.archived?(%Product{archived_at: nil})
      false

      iex> Product.archived?(%Product{archived_at: ~U[2026-01-01 00:00:00Z]})
      true
  """
  def archived?(%__MODULE__{archived_at: nil}), do: false
  def archived?(%__MODULE__{archived_at: _}), do: true

  @doc """
  Changeset for updating TikTok performance metrics.

  Used by ProductPerformanceSyncWorker to update GMV, items sold, and orders.
  """
  def performance_changeset(product, attrs) do
    product
    |> cast(attrs, [:gmv_cents, :items_sold, :orders, :performance_synced_at])
  end
end
