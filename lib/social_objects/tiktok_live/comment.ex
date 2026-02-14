defmodule SocialObjects.TiktokLive.Comment do
  @moduledoc """
  Represents a comment captured from a TikTok live stream.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type sentiment :: :positive | :neutral | :negative

  @type category ::
          :concern_complaint
          | :product_request
          | :question_confusion
          | :technical_issue
          | :praise_compliment
          | :general
          | :flash_sale

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          tiktok_user_id: String.t() | nil,
          tiktok_username: String.t() | nil,
          tiktok_nickname: String.t() | nil,
          comment_text: String.t() | nil,
          commented_at: DateTime.t() | nil,
          raw_event: map(),
          parsed_product_number: integer() | nil,
          sentiment: sentiment() | nil,
          category: category() | nil,
          classified_at: DateTime.t() | nil,
          brand_id: pos_integer() | nil,
          stream_id: pos_integer() | nil,
          product_set_product_id: pos_integer() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  schema "tiktok_comments" do
    field :tiktok_user_id, :string
    field :tiktok_username, :string
    field :tiktok_nickname, :string
    field :comment_text, :string
    field :commented_at, :utc_datetime
    field :raw_event, :map, default: %{}
    field :parsed_product_number, :integer

    # Classification fields
    field :sentiment, Ecto.Enum, values: [:positive, :neutral, :negative]

    field :category, Ecto.Enum,
      values: [
        :concern_complaint,
        :product_request,
        :question_confusion,
        :technical_issue,
        :praise_compliment,
        :general,
        :flash_sale
      ]

    field :classified_at, :utc_datetime

    belongs_to :brand, SocialObjects.Catalog.Brand
    belongs_to :stream, SocialObjects.TiktokLive.Stream
    belongs_to :product_set_product, SocialObjects.ProductSets.ProductSetProduct

    timestamps()
  end

  @doc false
  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [
      :stream_id,
      :tiktok_user_id,
      :tiktok_username,
      :tiktok_nickname,
      :comment_text,
      :commented_at,
      :raw_event,
      :product_set_product_id,
      :parsed_product_number
    ])
    |> validate_required([:brand_id, :stream_id, :tiktok_user_id, :comment_text, :commented_at])
    |> foreign_key_constraint(:stream_id)
    |> foreign_key_constraint(:product_set_product_id)
    |> foreign_key_constraint(:brand_id)
  end
end
