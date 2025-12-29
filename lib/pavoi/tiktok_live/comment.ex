defmodule Pavoi.TiktokLive.Comment do
  @moduledoc """
  Represents a comment captured from a TikTok live stream.
  """
  use Ecto.Schema
  import Ecto.Changeset

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
    field :category, Ecto.Enum, values: [:concern_complaint, :product_request, :question_confusion, :technical_issue, :praise_compliment, :general, :flash_sale]
    field :classified_at, :utc_datetime

    belongs_to :stream, Pavoi.TiktokLive.Stream
    belongs_to :session_product, Pavoi.Sessions.SessionProduct

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
      :session_product_id,
      :parsed_product_number
    ])
    |> validate_required([:stream_id, :tiktok_user_id, :comment_text, :commented_at])
    |> foreign_key_constraint(:stream_id)
    |> foreign_key_constraint(:session_product_id)
  end
end
