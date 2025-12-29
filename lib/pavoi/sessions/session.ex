defmodule Pavoi.Sessions.Session do
  @moduledoc """
  Represents a live streaming session for a brand.

  A session is a scheduled event where products are showcased to viewers,
  with an associated host, product lineup, and real-time state management.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "sessions" do
    field :name, :string
    field :slug, :string
    field :notes, :string
    field :notes_image_url, :string

    belongs_to :brand, Pavoi.Catalog.Brand
    has_many :session_products, Pavoi.Sessions.SessionProduct, preload_order: [asc: :position]
    has_one :session_state, Pavoi.Sessions.SessionState
    # Direct relationship (stream.session_id -> session.id)
    has_many :tiktok_streams, Pavoi.TiktokLive.Stream, foreign_key: :session_id
    # Legacy join table relationship (for backward compatibility)
    has_many :session_streams, Pavoi.TiktokLive.SessionStream, foreign_key: :session_id
    has_many :streams, through: [:session_streams, :stream]

    timestamps()
  end

  @doc false
  def changeset(session, attrs) do
    session
    |> cast(attrs, [:brand_id, :name, :slug, :notes, :notes_image_url])
    |> validate_required([:brand_id, :name, :slug])
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:brand_id)
  end
end
