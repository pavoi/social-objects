defmodule Hudson.Sync.Queue do
  @moduledoc """
  Minimal local sync queue for Phase 2 pilot.

  Stores operations in the SQLite LocalRepo and provides helpers to
  enqueue, fetch pending, and mark completion/failure.
  """

  import Ecto.Query
  alias Hudson.LocalRepo
  alias Hudson.Sync.Operation

  @default_limit 50

  def enqueue(action, payload \\ %{}) do
    %{}
    |> Map.put(:action, action)
    |> Map.put(:payload, payload)
    |> Operation.enqueue_changeset()
    |> LocalRepo.insert()
  end

  def pending(limit \\ @default_limit) do
    Operation
    |> where([op], op.status == "pending")
    |> order_by([op], asc: op.id)
    |> limit(^limit)
    |> LocalRepo.all()
  end

  def mark_done(%Operation{} = op) do
    op
    |> Operation.status_changeset(%{status: "done"})
    |> LocalRepo.update()
  end

  def mark_failed(%Operation{} = op, reason) do
    op
    |> Operation.status_changeset(%{
      status: "failed",
      attempts: op.attempts + 1,
      last_error: to_string(reason)
    })
    |> LocalRepo.update()
  end
end
