defmodule Pavoi.Repo.Migrations.AddSessionIdToTiktokStreams do
  use Ecto.Migration

  def change do
    alter table(:tiktok_streams) do
      add :session_id, references(:sessions, on_delete: :nilify_all)
    end

    create index(:tiktok_streams, [:session_id])

    # Migrate existing session_streams links to the new session_id column
    # Takes the first linked session per stream (by linked_at timestamp)
    execute(
      """
      UPDATE tiktok_streams
      SET session_id = subq.session_id
      FROM (
        SELECT DISTINCT ON (stream_id) stream_id, session_id
        FROM session_streams
        ORDER BY stream_id, linked_at ASC
      ) subq
      WHERE tiktok_streams.id = subq.stream_id
      """,
      # Down migration: no-op (data is preserved in session_streams table)
      "SELECT 1"
    )
  end
end
