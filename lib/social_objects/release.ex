defmodule SocialObjects.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :social_objects

  def migrate do
    IO.puts("[Release] Starting migration process...")

    try do
      load_app()
      IO.puts("[Release] Application loaded successfully")

      for repo <- repos() do
        IO.puts("[Release] Running migrations for #{inspect(repo)}...")

        # First, check pending migrations
        {:ok, pending, _} =
          Ecto.Migrator.with_repo(repo, fn repo ->
            Ecto.Migrator.migrations(repo)
            |> Enum.filter(fn {status, _version, _name} -> status == :down end)
          end)

        IO.puts("[Release] Found #{length(pending)} pending migrations")

        for {_status, version, name} <- pending do
          IO.puts("[Release]   - #{version}: #{name}")
        end

        # Run migrations
        case Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true, log: :info)) do
          {:ok, migrations_run, _} ->
            IO.puts("[Release] Successfully ran #{length(migrations_run)} migrations")
            {:ok, migrations_run}

          {:error, reason} ->
            IO.puts("[Release] ERROR: Migration failed - #{inspect(reason)}")
            raise "Migration failed: #{inspect(reason)}"
        end
      end

      IO.puts("[Release] All migrations completed successfully!")
    rescue
      e in [Postgrex.Error, Ecto.MigrationError] ->
        IO.puts("[Release] FATAL DATABASE ERROR during migration:")
        IO.puts("[Release] #{inspect(e)}")
        reraise e, __STACKTRACE__

      e ->
        IO.puts("[Release] FATAL ERROR during migration:")
        IO.puts("[Release] #{Exception.message(e)}")
        reraise e, __STACKTRACE__
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    IO.puts("[Release] Loading application and starting SSL...")
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)

    # Railway's internal network isn't available during release phase,
    # so use DATABASE_PUBLIC_URL if set
    if public_url = System.get_env("DATABASE_PUBLIC_URL") do
      IO.puts("[Release] Using DATABASE_PUBLIC_URL for migrations")
      Application.put_env(:social_objects, SocialObjects.Repo, url: public_url)
    end
  end
end
