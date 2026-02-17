defmodule SocialObjects.Creators.ImportAudit do
  @moduledoc """
  Tracks import runs for debugging, reruns, and operational visibility.

  Each import run creates an audit record that tracks:
  - Source and file information
  - Progress counts (rows processed, created, updated)
  - Error samples for debugging
  - Status transitions (pending -> running -> completed/failed)
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type status :: :pending | :running | :completed | :failed

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          brand_id: pos_integer() | nil,
          source: String.t(),
          file_path: String.t() | nil,
          file_checksum: String.t() | nil,
          status: String.t(),
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          rows_processed: integer(),
          creators_created: integer(),
          creators_updated: integer(),
          samples_created: integer(),
          error_count: integer(),
          errors_sample: map() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  @statuses ~w(pending running completed failed)

  schema "import_audits" do
    belongs_to :brand, SocialObjects.Catalog.Brand

    field :source, :string
    field :file_path, :string
    field :file_checksum, :string
    field :status, :string, default: "pending"
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    # Counts
    field :rows_processed, :integer, default: 0
    field :creators_created, :integer, default: 0
    field :creators_updated, :integer, default: 0
    field :samples_created, :integer, default: 0
    field :error_count, :integer, default: 0

    # Error details (first N errors for debugging)
    field :errors_sample, :map

    timestamps()
  end

  @doc false
  def changeset(import_audit, attrs) do
    import_audit
    |> cast(attrs, [
      :brand_id,
      :source,
      :file_path,
      :file_checksum,
      :status,
      :started_at,
      :finished_at,
      :rows_processed,
      :creators_created,
      :creators_updated,
      :samples_created,
      :error_count,
      :errors_sample
    ])
    |> validate_required([:brand_id, :source])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:brand_id)
    |> unique_constraint([:brand_id, :source, :file_checksum],
      name: :import_audits_no_duplicate_runs
    )
  end

  @doc """
  Returns the list of valid statuses.
  """
  def statuses, do: @statuses
end
