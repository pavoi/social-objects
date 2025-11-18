defmodule Hudson.LocalRepoMigrator do
  @moduledoc """
  Ensures the SQLite local cache schema is migrated on startup.
  """

  require Logger
  alias Hudson.Desktop.Bootstrap

  defp migrations_path do
    Application.app_dir(:hudson, "priv/local_repo/migrations")
  end

  def migrate do
    Bootstrap.ensure_data_dir!()
    path = migrations_path()

    if File.dir?(path) do
      Logger.info("Running local SQLite migrations for Hudson.LocalRepo")

      Ecto.Migrator.with_repo(Hudson.LocalRepo, fn repo ->
        Ecto.Migrator.run(repo, path, :up, all: true)
      end)
    else
      Logger.warning("SQLite migrations path missing: #{path}")
      :ok
    end
  end
end
