defmodule SocialObjects.ProductSets.ProductSetState do
  @moduledoc """
  Tracks the real-time state of a product set during live streaming.

  Stores the current product being featured, which image is displayed,
  and the most recent message from the host. This state is synced across
  all connected clients via PubSub.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type message_color :: :amber | :blue | :green | :red | :purple | :gray

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          current_image_index: integer(),
          current_host_message_text: String.t() | nil,
          current_host_message_id: String.t() | nil,
          current_host_message_timestamp: DateTime.t() | nil,
          current_host_message_color: message_color() | nil,
          updated_at: DateTime.t() | nil,
          product_set_id: pos_integer() | nil,
          current_product_set_product_id: pos_integer() | nil
        }

  @valid_colors ~w(amber blue green red purple gray)a

  schema "product_set_states" do
    field :current_image_index, :integer, default: 0
    field :current_host_message_text, :string
    field :current_host_message_id, :string
    field :current_host_message_timestamp, :utc_datetime
    field :current_host_message_color, Ecto.Enum, values: @valid_colors
    field :updated_at, :utc_datetime

    belongs_to :product_set, SocialObjects.ProductSets.ProductSet
    belongs_to :current_product_set_product, SocialObjects.ProductSets.ProductSetProduct
  end

  @doc false
  def changeset(state, attrs) do
    state
    |> cast(attrs, [
      :product_set_id,
      :current_product_set_product_id,
      :current_image_index,
      :current_host_message_text,
      :current_host_message_id,
      :current_host_message_timestamp,
      :current_host_message_color
    ])
    |> validate_required([:product_set_id])
    |> validate_number(:current_image_index, greater_than_or_equal_to: 0)
    |> unique_constraint(:product_set_id)
    |> foreign_key_constraint(:product_set_id)
    |> foreign_key_constraint(:current_product_set_product_id)
    |> put_change(:updated_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end
end
