defmodule Pavoi.Repo.Migrations.AddUniqueIndexOnCapturingStreams do
  use Ecto.Migration

  @doc """
  Adds a partial unique index to prevent multiple streams from capturing
  the same TikTok room simultaneously.

  This prevents race conditions where the monitor worker might create
  duplicate stream records for the same live broadcast.
  """
  def change do
    # Only allow one "capturing" stream per room_id at a time
    create unique_index(:tiktok_streams, [:room_id],
      where: "status = 'capturing'",
      name: :tiktok_streams_room_id_capturing_unique
    )
  end
end
