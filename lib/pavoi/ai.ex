defmodule Pavoi.AI do
  @moduledoc """
  The AI context for managing AI-powered features like talking points generation.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Pavoi.AI.TalkingPointsGeneration
  alias Pavoi.Catalog
  alias Pavoi.Repo
  alias Pavoi.Sessions
  alias Pavoi.Workers.TalkingPointsWorker

  @doc """
  Generates talking points for a single product asynchronously.

  Creates a background job to generate AI-powered talking points for the given product.
  Returns `{:ok, generation}` with a TalkingPointsGeneration record that can be used
  to track progress.

  ## Parameters
    - product_id: Integer ID of the product

  ## Example
      iex> AI.generate_talking_points_async(123)
      {:ok, %TalkingPointsGeneration{job_id: "abc-123", status: "pending", ...}}
  """
  def generate_talking_points_async(product_id) when is_integer(product_id) do
    generate_talking_points_async([product_id], nil)
  end

  @doc """
  Generates talking points for all products in a session asynchronously.

  Creates a background job to generate AI-powered talking points for all products
  in the given session. Progress can be tracked via PubSub broadcasts.

  ## Parameters
    - session_id: Integer ID of the session

  ## Example
      iex> AI.generate_session_talking_points_async(456)
      {:ok, %TalkingPointsGeneration{job_id: "def-456", status: "pending", ...}}
  """
  def generate_session_talking_points_async(session_id) when is_integer(session_id) do
    session = Sessions.get_session!(session_id)

    product_ids =
      session
      |> Repo.preload(:session_products)
      |> Map.get(:session_products)
      |> Enum.map(& &1.product_id)

    if Enum.empty?(product_ids) do
      {:error, "Session has no products"}
    else
      generate_talking_points_async(product_ids, session_id)
    end
  rescue
    Ecto.NoResultsError ->
      {:error, "Session not found"}
  end

  @doc """
  Internal function to generate talking points for a list of product IDs.

  Returns:
  - `{:ok, generation}` on success
  - `{:error, reason}` on failure (empty list, invalid product IDs, etc.)
  """
  def generate_talking_points_async(product_ids, session_id \\ nil) when is_list(product_ids) do
    # Validate input
    cond do
      Enum.empty?(product_ids) ->
        {:error, :no_products}

      not Enum.all?(product_ids, &is_integer/1) ->
        {:error, :invalid_product_ids}

      true ->
        # Generate a unique job ID
        job_id = generate_job_id()

        # Create the generation record
        attrs = %{
          job_id: job_id,
          session_id: session_id,
          product_ids: product_ids,
          total_count: length(product_ids)
        }

        with {:ok, generation} <- create_generation(attrs),
             {:ok, _job} <- enqueue_worker(generation) do
          # Broadcast that generation has started
          broadcast_generation_event({:generation_started, generation})

          {:ok, generation}
        end
    end
  end

  @doc """
  Gets the status of a talking points generation job.
  """
  def get_generation(job_id) when is_binary(job_id) do
    Repo.get_by(TalkingPointsGeneration, job_id: job_id)
  end

  @doc """
  Gets the status of a talking points generation by ID.
  """
  def get_generation!(id) do
    Repo.get!(TalkingPointsGeneration, id)
  end

  @doc """
  Lists all talking points generations for a session.
  """
  def list_session_generations(session_id) do
    TalkingPointsGeneration
    |> where([g], g.session_id == ^session_id)
    |> order_by([g], desc: g.inserted_at)
    |> Repo.all()
  end

  @doc """
  Creates a new talking points generation record.
  """
  def create_generation(attrs) do
    attrs
    |> TalkingPointsGeneration.start_changeset()
    |> Repo.insert()
  end

  @doc """
  Updates a generation with new progress/results.
  """
  def update_generation(%TalkingPointsGeneration{} = generation, attrs) do
    generation
    |> TalkingPointsGeneration.progress_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Adds a successful result for a product to the generation.
  """
  def add_generation_result(generation, product_id, talking_points) do
    generation
    |> TalkingPointsGeneration.add_result(product_id, talking_points)
    |> Repo.update()
  end

  @doc """
  Adds an error for a product to the generation.
  """
  def add_generation_error(generation, product_id, error_message) do
    generation
    |> TalkingPointsGeneration.add_error(product_id, error_message)
    |> Repo.update()
  end

  @doc """
  Applies the generated talking points to the actual products.

  For single product generation or batch generation, this updates the
  `talking_points_md` field on the products with the generated content.

  Returns `{:ok, results}` where results is a list of tuples:
  - `{:ok, product_id, updated_product}` for successful updates
  - `{:error, product_id, reason}` for failed updates

  Returns `{:error, :no_results}` if there are no results to apply.
  """
  def apply_generated_talking_points(%TalkingPointsGeneration{} = generation) do
    if map_size(generation.results) == 0 do
      Logger.warning("No talking points to apply for generation #{generation.job_id}")
      {:error, :no_results}
    else
      results =
        for {product_id_str, talking_points} <- generation.results do
          product_id = String.to_integer(product_id_str)

          with {:ok, product} <- Catalog.get_product(product_id),
               {:ok, updated_product} <-
                 Catalog.update_product(product, %{talking_points_md: talking_points}) do
            Logger.debug("Applied talking points to product #{product_id}")
            {:ok, product_id, updated_product}
          else
            nil ->
              error = "Product not found"
              Logger.warning("Failed to apply talking points to product #{product_id}: #{error}")
              {:error, product_id, error}

            {:error, changeset} ->
              error = "Failed to update: #{inspect(changeset.errors)}"
              Logger.warning("Failed to apply talking points to product #{product_id}: #{error}")
              {:error, product_id, error}
          end
        end

      successes = Enum.count(results, &match?({:ok, _, _}, &1))
      failures = Enum.count(results, &match?({:error, _, _}, &1))

      Logger.info("Applied talking points: #{successes} succeeded, #{failures} failed")

      {:ok, results}
    end
  end

  # Private functions

  defp generate_job_id do
    "tp_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
  end

  defp enqueue_worker(generation) do
    %{
      job_id: generation.job_id,
      product_ids: generation.product_ids,
      session_id: generation.session_id
    }
    |> TalkingPointsWorker.new()
    |> Oban.insert()
  end

  @doc """
  Broadcasts a generation event via PubSub.

  Events:
  - `{:generation_started, generation}`
  - `{:generation_progress, generation, product_id, product_name}`
  - `{:generation_completed, generation}`
  - `{:generation_failed, generation, reason}`
  """
  def broadcast_generation_event({event, _} = message)
      when event in [:generation_started, :generation_completed, :generation_failed] do
    Phoenix.PubSub.broadcast(Pavoi.PubSub, "ai:talking_points", message)
  end

  def broadcast_generation_event(
        {:generation_progress, generation, _product_id, _product_name} = message
      ) do
    # Broadcast to general channel
    Phoenix.PubSub.broadcast(Pavoi.PubSub, "ai:talking_points", message)
    # Also broadcast to job-specific channel
    Phoenix.PubSub.broadcast(Pavoi.PubSub, "ai:talking_points:#{generation.job_id}", message)
  end

  @doc """
  Subscribes to talking points generation events.

  ## Examples
      # Subscribe to all generation events
      AI.subscribe()

      # Subscribe to a specific job's events
      AI.subscribe("tp_abc123...")
  """
  def subscribe(job_id \\ nil) do
    topic =
      if job_id do
        "ai:talking_points:#{job_id}"
      else
        "ai:talking_points"
      end

    Phoenix.PubSub.subscribe(Pavoi.PubSub, topic)
  end
end
