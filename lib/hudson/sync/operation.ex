defmodule Hudson.Sync.Operation do
  @moduledoc """
  Local operation log for the SQLite cache -> Neon sync queue.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "sync_operations" do
    field :action, :string
    field :payload, :map
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :last_error, :string

    timestamps(type: :utc_datetime)
  end

  def enqueue_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:action, :payload])
    |> validate_required([:action])
  end

  def status_changeset(operation, attrs) do
    operation
    |> cast(attrs, [:status, :attempts, :last_error])
    |> validate_required([:status])
  end
end
