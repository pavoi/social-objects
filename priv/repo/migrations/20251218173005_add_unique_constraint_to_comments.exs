defmodule Pavoi.Repo.Migrations.AddUniqueConstraintToComments do
  use Ecto.Migration

  def up do
    # First, remove duplicate comments keeping only the first (lowest id) of each group
    execute """
    DELETE FROM tiktok_comments
    WHERE id NOT IN (
      SELECT MIN(id)
      FROM tiktok_comments
      GROUP BY stream_id, tiktok_user_id, commented_at
    )
    """

    # Add unique constraint to prevent future duplicates
    # A user can't send two messages at the exact same second
    create unique_index(:tiktok_comments, [:stream_id, :tiktok_user_id, :commented_at],
             name: :tiktok_comments_unique_per_user_timestamp
           )
  end

  def down do
    drop index(:tiktok_comments, [:stream_id, :tiktok_user_id, :commented_at],
           name: :tiktok_comments_unique_per_user_timestamp
         )
  end
end
