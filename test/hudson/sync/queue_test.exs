defmodule Hudson.Sync.QueueTest do
  use ExUnit.Case, async: false

  alias Hudson.Sync.{Operation, Queue}
  alias Hudson.{LocalRepo, LocalRepoMigrator}

  setup_all do
    LocalRepoMigrator.migrate()
    :ok
  end

  setup do
    LocalRepo.delete_all(Operation)
    :ok
  end

  test "enqueue -> pending -> mark_done" do
    {:ok, op} = Queue.enqueue("test_action", %{"foo" => "bar"})

    [pending] = Queue.pending()
    assert pending.id == op.id
    assert pending.status == "pending"

    {:ok, done} = Queue.mark_done(pending)
    assert done.status == "done"
  end

  test "mark_failed increments attempts" do
    {:ok, op} = Queue.enqueue("update", %{})

    {:ok, failed} = Queue.mark_failed(op, "network error")

    assert failed.status == "failed"
    assert failed.attempts == 1
    assert failed.last_error =~ "network error"
  end
end
