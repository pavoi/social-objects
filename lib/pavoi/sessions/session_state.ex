defmodule Pavoi.Sessions.SessionState do
  @moduledoc """
  Tracks the real-time state of a live session.

  Stores the current product being featured, which image is displayed,
  and the most recent message from the host. This state is synced across
  all connected clients via PubSub.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "session_states" do
    field :current_image_index, :integer, default: 0
    field :current_host_message_text, :string
    field :current_host_message_id, :string
    field :current_host_message_timestamp, :utc_datetime
    field :updated_at, :utc_datetime

    belongs_to :session, Pavoi.Sessions.Session
    belongs_to :current_session_product, Pavoi.Sessions.SessionProduct
  end

  @doc false
  def changeset(state, attrs) do
    state
    |> cast(attrs, [
      :session_id,
      :current_session_product_id,
      :current_image_index,
      :current_host_message_text,
      :current_host_message_id,
      :current_host_message_timestamp
    ])
    |> validate_required([:session_id])
    |> validate_number(:current_image_index, greater_than_or_equal_to: 0)
    |> unique_constraint(:session_id)
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:current_session_product_id)
    |> put_change(:updated_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end
end
