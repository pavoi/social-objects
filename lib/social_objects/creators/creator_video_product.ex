defmodule SocialObjects.Creators.CreatorVideoProduct do
  @moduledoc """
  Junction table linking videos to products they promote.

  Tracks which products are featured in creator videos, enabling
  analysis of product-level video performance.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          creator_video_id: pos_integer() | nil,
          product_id: pos_integer() | nil,
          tiktok_product_id: String.t() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  schema "creator_video_products" do
    belongs_to :creator_video, SocialObjects.Creators.CreatorVideo
    belongs_to :product, SocialObjects.Catalog.Product

    # For matching when product not in DB yet
    field :tiktok_product_id, :string

    timestamps()
  end

  @doc false
  def changeset(creator_video_product, attrs) do
    creator_video_product
    |> cast(attrs, [:creator_video_id, :product_id, :tiktok_product_id])
    |> validate_required([:creator_video_id])
    |> unique_constraint([:creator_video_id, :product_id])
    |> foreign_key_constraint(:creator_video_id)
    |> foreign_key_constraint(:product_id)
  end
end
