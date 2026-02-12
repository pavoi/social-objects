defmodule SocialObjects.Monitoring do
  @moduledoc """
  Context for monitoring system health, worker status, and job queues.

  Provides query functions for:
  - Sync status timestamps from system_settings
  - Oban queue statistics
  - Failed/retryable job information
  - Currently executing workers
  - Rate limit status
  """

  import Ecto.Query
  alias SocialObjects.Repo
  alias SocialObjects.Settings.SystemSetting
  alias SocialObjects.Workers.Registry

  @doc """
  Fetches all sync status timestamps for a brand (or all brands if nil).

  Returns a map of status_key => DateTime for each worker that has a status_key.
  """
  def get_all_sync_statuses(brand_id) do
    # Get all status keys from the registry
    status_keys =
      Registry.all_workers()
      |> Enum.map(& &1.status_key)
      |> Enum.reject(&is_nil/1)

    query =
      if brand_id do
        from(s in SystemSetting,
          where: s.brand_id == ^brand_id,
          where: s.key in ^status_keys
        )
      else
        from(s in SystemSetting,
          where: s.key in ^status_keys
        )
      end

    query
    |> Repo.all()
    |> Enum.reduce(%{}, fn setting, acc ->
      key = {setting.brand_id, setting.key}
      datetime = parse_datetime(setting.value)
      Map.put(acc, key, datetime)
    end)
  end

  @doc """
  Gets the status for a specific worker and brand.
  """
  def get_worker_status(brand_id, status_key) when is_binary(status_key) do
    case Repo.get_by(SystemSetting, brand_id: brand_id, key: status_key) do
      nil -> nil
      setting -> parse_datetime(setting.value)
    end
  end

  @doc """
  Gets aggregated Oban queue statistics.

  Returns a map with:
  - :pending - count of available + scheduled jobs
  - :running - count of executing jobs
  - :failed - count of discarded + retryable jobs
  - :by_queue - breakdown by queue name
  """
  def get_oban_queue_stats do
    query =
      from(j in Oban.Job,
        where: j.state in ["available", "scheduled", "executing", "retryable", "discarded"],
        group_by: [j.queue, j.state],
        select: %{
          queue: j.queue,
          state: j.state,
          count: count(j.id)
        }
      )

    stats = Repo.all(query)

    # Aggregate by state
    pending =
      stats
      |> Enum.filter(&(&1.state in ["available", "scheduled"]))
      |> Enum.map(& &1.count)
      |> Enum.sum()

    running =
      stats
      |> Enum.filter(&(&1.state == "executing"))
      |> Enum.map(& &1.count)
      |> Enum.sum()

    failed =
      stats
      |> Enum.filter(&(&1.state in ["discarded", "retryable"]))
      |> Enum.map(& &1.count)
      |> Enum.sum()

    # Group by queue
    by_queue =
      stats
      |> Enum.group_by(& &1.queue)
      |> Enum.map(fn {queue, queue_stats} ->
        {queue,
         %{
           pending:
             queue_stats
             |> Enum.filter(&(&1.state in ["available", "scheduled"]))
             |> Enum.map(& &1.count)
             |> Enum.sum(),
           running:
             queue_stats
             |> Enum.filter(&(&1.state == "executing"))
             |> Enum.map(& &1.count)
             |> Enum.sum(),
           failed:
             queue_stats
             |> Enum.filter(&(&1.state in ["discarded", "retryable"]))
             |> Enum.map(& &1.count)
             |> Enum.sum()
         }}
      end)
      |> Map.new()

    %{
      pending: pending,
      running: running,
      failed: failed,
      by_queue: by_queue
    }
  end

  @doc """
  Gets recent failed (discarded/retryable) jobs with error information.

  Options:
  - :limit - max jobs to return (default 10)
  - :brand_id - filter by brand_id in job args
  """
  def get_recent_failed_jobs(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    brand_id = Keyword.get(opts, :brand_id)

    query =
      from(j in Oban.Job,
        where: j.state in ["discarded", "retryable"],
        order_by: [desc: j.attempted_at],
        limit: ^limit
      )

    query =
      if brand_id do
        from(j in query,
          where: fragment("?->>'brand_id' = ?", j.args, ^to_string(brand_id))
        )
      else
        query
      end

    query
    |> Repo.all()
    |> Enum.map(&format_failed_job/1)
  end

  @doc """
  Gets currently active workers (pending or running) for a specific brand.

  Returns a list of maps with:
  - :worker_key - the worker registry key
  - :state - "pending" (available/scheduled) or "running" (executing)
  - :started_at - when the job was attempted (for executing jobs)
  """
  def get_running_workers_for_brand(brand_id) do
    from(j in Oban.Job,
      where: j.state in ["available", "scheduled", "executing"],
      where: fragment("?->>'brand_id' = ?", j.args, ^to_string(brand_id)),
      order_by: [asc: j.inserted_at]
    )
    |> Repo.all()
    |> Enum.map(fn job ->
      worker_key = worker_module_to_key(job.worker)
      state = if job.state == "executing", do: :running, else: :pending

      %{worker_key: worker_key, state: state, started_at: job.attempted_at}
    end)
  end

  @doc """
  Gets the latest failed state (retryable/discarded) per worker for a brand.

  Returns a map keyed by worker key:
  - :state - "retryable" or "discarded"
  - :attempted_at - most recent failure timestamp
  - :error - most recent error message
  - :job_id - Oban job id
  """
  def get_failed_worker_states_for_brand(brand_id) do
    from(j in Oban.Job,
      where: j.state in ["retryable", "discarded"],
      where: fragment("?->>'brand_id' = ?", j.args, ^to_string(brand_id)),
      order_by: [desc: j.attempted_at, desc: j.inserted_at]
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn job, acc ->
      worker_key = worker_module_to_key(job.worker)

      cond do
        is_nil(worker_key) ->
          acc

        Map.has_key?(acc, worker_key) ->
          acc

        true ->
          Map.put(acc, worker_key, %{
            job_id: job.id,
            state: job.state,
            attempted_at: job.attempted_at || job.inserted_at,
            error: extract_job_error(job)
          })
      end
    end)
  end

  @doc """
  Gets rate limit info for creator enrichment worker.

  Returns:
  - :streak - consecutive rate limit count
  - :last_limited_at - when last rate limited
  - :in_cooldown - whether currently in cooldown
  """
  def get_enrichment_rate_limit_info(brand_id) do
    streak_setting =
      Repo.get_by(SystemSetting, brand_id: brand_id, key: "enrichment_rate_limit_streak")

    last_limited_setting =
      Repo.get_by(SystemSetting, brand_id: brand_id, key: "enrichment_last_rate_limited_at")

    streak =
      case streak_setting do
        nil -> 0
        setting -> String.to_integer(setting.value)
      end

    last_limited_at =
      case last_limited_setting do
        nil -> nil
        setting -> parse_datetime(setting.value)
      end

    # Check if in cooldown (within 10 minutes of last rate limit)
    in_cooldown =
      case last_limited_at do
        nil ->
          false

        dt ->
          cooldown_seconds = 10 * 60
          seconds_since = DateTime.diff(DateTime.utc_now(), dt, :second)
          seconds_since < cooldown_seconds
      end

    %{
      streak: streak,
      last_limited_at: last_limited_at,
      in_cooldown: in_cooldown
    }
  end

  @doc """
  Retries a specific failed job by ID.
  """
  def retry_job(job_id) do
    case Repo.get(Oban.Job, job_id) do
      nil ->
        {:error, :not_found}

      job ->
        Oban.retry_job(job.id)
    end
  end

  # Private helpers

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> nil
    end
  end

  defp format_failed_job(job) do
    %{
      id: job.id,
      worker: job.worker,
      worker_name: worker_display_name(job.worker),
      state: job.state,
      attempted_at: job.attempted_at,
      error: extract_job_error(job),
      attempt: job.attempt,
      max_attempts: job.max_attempts,
      brand_id: get_in(job.args, ["brand_id"])
    }
  end

  defp extract_job_error(job) do
    case job.errors do
      [%{"error" => error} | _] -> error
      [%{"message" => msg} | _] -> msg
      [error | _] when is_map(error) -> inspect(error)
      _ -> "Unknown error"
    end
  end

  defp worker_display_name(worker_module) when is_binary(worker_module) do
    # Find matching worker in registry
    worker =
      Registry.all_workers()
      |> Enum.find(fn w -> "#{w.module}" == worker_module end)

    case worker do
      nil -> worker_module |> String.split(".") |> List.last()
      w -> w.name
    end
  end

  defp worker_module_to_key(worker_module) when is_binary(worker_module) do
    # Oban stores worker as "SocialObjects.Workers.Foo" but Elixir modules
    # stringify as "Elixir.SocialObjects.Workers.Foo", so convert to atom for comparison
    module_atom = String.to_existing_atom("Elixir." <> worker_module)

    worker =
      Registry.all_workers()
      |> Enum.find(fn w -> w.module == module_atom end)

    case worker do
      nil -> nil
      w -> w.key
    end
  rescue
    ArgumentError -> nil
  end
end
