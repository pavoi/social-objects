defmodule SocialObjects.TiktokShop.Auth do
  @moduledoc """
  Schema for TikTok Shop authentication credentials.
  Stores access tokens, refresh tokens, and shop-specific information.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          access_token: String.t() | nil,
          refresh_token: String.t() | nil,
          access_token_expires_at: DateTime.t() | nil,
          refresh_token_expires_at: DateTime.t() | nil,
          shop_id: String.t() | nil,
          shop_cipher: String.t() | nil,
          shop_name: String.t() | nil,
          shop_code: String.t() | nil,
          region: String.t() | nil,
          brand_id: pos_integer() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  schema "tiktok_shop_auth" do
    field :access_token, :string
    field :refresh_token, :string
    field :access_token_expires_at, :utc_datetime
    field :refresh_token_expires_at, :utc_datetime
    field :shop_id, :string
    field :shop_cipher, :string
    field :shop_name, :string
    field :shop_code, :string
    field :region, :string

    belongs_to :brand, SocialObjects.Catalog.Brand

    timestamps()
  end

  @doc false
  def changeset(auth, attrs) do
    auth
    |> cast(attrs, [
      :access_token,
      :refresh_token,
      :access_token_expires_at,
      :refresh_token_expires_at,
      :shop_id,
      :shop_cipher,
      :shop_name,
      :shop_code,
      :region
    ])
    |> validate_required([:brand_id, :access_token, :refresh_token])
    |> foreign_key_constraint(:brand_id)
  end
end
