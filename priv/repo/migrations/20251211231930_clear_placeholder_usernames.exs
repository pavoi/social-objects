defmodule Pavoi.Repo.Migrations.ClearPlaceholderUsernames do
  use Ecto.Migration

  def up do
    # Clear placeholder usernames that were generated from names + random hex suffix
    # Pattern: lowercase letters/numbers/underscores followed by _[8 hex chars]
    # e.g., "john_smith_a1b2c3d4", "c_n_612c927c", "unknown_deadbeef"
    execute """
    UPDATE creators
    SET tiktok_username = NULL
    WHERE tiktok_username ~ '^[a-z0-9_]+_[a-f0-9]{8}$'
    """
  end

  def down do
    # Cannot restore placeholder usernames - they were randomly generated
    :ok
  end
end
