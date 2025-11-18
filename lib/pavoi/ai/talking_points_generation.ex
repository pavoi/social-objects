defmodule Pavoi.AI.TalkingPointsGeneration do
  @moduledoc """
  Schema for tracking AI talking points generation jobs.
  Stores progress, results, and errors for both single product and batch generation.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Pavoi.Sessions.Session

  @type t :: %__MODULE__{
          id: integer(),
          job_id: String.t(),
          session_id: integer() | nil,
          product_ids: [integer()],
          status: String.t(),
          total_count: integer(),
          completed_count: integer(),
          failed_count: integer(),
          results: map(),
          errors: map(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "talking_points_generations" do
    field :job_id, :string
    field :product_ids, {:array, :integer}
    field :status, :string, default: "pending"
    field :total_count, :integer
    field :completed_count, :integer, default: 0
    field :failed_count, :integer, default: 0
    field :results, :map, default: %{}
    field :errors, :map, default: %{}

    belongs_to :session, Session

    timestamps(type: :utc_datetime)
  end

  # Status values:
  # - "pending" - Job queued but not started
  # - "processing" - Currently generating talking points
  # - "completed" - All products processed successfully
  # - "partial" - Some products succeeded, some failed
  # - "failed" - Job failed completely
  @valid_statuses ~w(pending processing completed partial failed)

  @doc false
  def changeset(generation, attrs) do
    generation
    |> cast(attrs, [
      :job_id,
      :session_id,
      :product_ids,
      :status,
      :total_count,
      :completed_count,
      :failed_count,
      :results,
      :errors
    ])
    |> validate_required([:job_id, :product_ids, :status, :total_count])
    |> validate_inclusion(:status, @valid_statuses)
    |> foreign_key_constraint(:session_id)
  end

  @doc """
  Creates a changeset for starting a new generation job.
  """
  def start_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:job_id, :session_id, :product_ids, :total_count])
    |> put_change(:status, "pending")
    |> put_change(:completed_count, 0)
    |> put_change(:failed_count, 0)
    |> put_change(:results, %{})
    |> put_change(:errors, %{})
    |> validate_required([:job_id, :product_ids, :total_count])
  end

  @doc """
  Updates the generation with progress information.
  """
  def progress_changeset(generation, attrs) do
    generation
    |> cast(attrs, [:status, :completed_count, :failed_count, :results, :errors])
    |> validate_inclusion(:status, @valid_statuses)
  end

  @doc """
  Adds a successful result for a product.
  """
  def add_result(generation, product_id, talking_points) do
    new_results = Map.put(generation.results, to_string(product_id), talking_points)
    new_completed = generation.completed_count + 1

    status =
      cond do
        new_completed == generation.total_count -> "completed"
        new_completed > 0 -> "processing"
        true -> generation.status
      end

    generation
    |> change()
    |> put_change(:results, new_results)
    |> put_change(:completed_count, new_completed)
    |> put_change(:status, status)
  end

  @doc """
  Adds a failure for a product.
  """
  def add_error(generation, product_id, error_message) do
    new_errors = Map.put(generation.errors, to_string(product_id), error_message)
    new_failed = generation.failed_count + 1
    total_processed = generation.completed_count + new_failed

    status =
      cond do
        total_processed == generation.total_count and generation.completed_count > 0 -> "partial"
        total_processed == generation.total_count -> "failed"
        true -> "processing"
      end

    generation
    |> change()
    |> put_change(:errors, new_errors)
    |> put_change(:failed_count, new_failed)
    |> put_change(:status, status)
  end
end
