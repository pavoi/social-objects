defmodule SocialObjects.AI do
  @moduledoc """
  The AI context for managing AI-powered features like talking points generation.
  """

  import Ecto.Query, warn: false
  require Logger

  alias SocialObjects.AI.TalkingPointsGeneration
  alias SocialObjects.Catalog
  alias SocialObjects.Catalog.Product
  alias SocialObjects.ProductSets
  alias SocialObjects.Repo
  alias SocialObjects.Workers.TalkingPointsWorker

  @spec generate_talking_points_async(pos_integer(), pos_integer()) ::
          {:ok, TalkingPointsGeneration.t()} | {:error, term()}
  @doc """
  Generates talking points for a single product asynchronously.

  Creates a background job to generate AI-powered talking points for the given product.
  Returns `{:ok, generation}` with a TalkingPointsGeneration record that can be used
  to track progress.

  ## Parameters
    - brand_id: Integer ID of the brand
    - product_id: Integer ID of the product

  ## Example
      iex> AI.generate_talking_points_async(brand_id, 123)
      {:ok, %TalkingPointsGeneration{job_id: "abc-123", status: "pending", ...}}
  """
  def generate_talking_points_async(brand_id, product_id)
      when is_integer(brand_id) and is_integer(product_id) do
    generate_talking_points_async(brand_id, [product_id], nil)
  end

  @spec generate_product_set_talking_points_async(pos_integer(), pos_integer()) ::
          {:ok, TalkingPointsGeneration.t()} | {:error, term()}
  @doc """
  Generates talking points for all products in a product set asynchronously.

  Creates a background job to generate AI-powered talking points for all products
  in the given product set. Progress can be tracked via PubSub broadcasts.

  ## Parameters
    - brand_id: Integer ID of the brand
    - product_set_id: Integer ID of the product set

  ## Example
      iex> AI.generate_product_set_talking_points_async(brand_id, 456)
      {:ok, %TalkingPointsGeneration{job_id: "def-456", status: "pending", ...}}
  """
  def generate_product_set_talking_points_async(brand_id, product_set_id)
      when is_integer(brand_id) and is_integer(product_set_id) do
    product_set = ProductSets.get_product_set!(brand_id, product_set_id)

    product_ids =
      product_set
      |> Repo.preload(:product_set_products)
      |> Map.get(:product_set_products)
      |> Enum.map(& &1.product_id)

    if Enum.empty?(product_ids) do
      {:error, "Product set has no products"}
    else
      generate_talking_points_async(brand_id, product_ids, product_set_id)
    end
  rescue
    Ecto.NoResultsError ->
      {:error, "Product set not found"}
  end

  @spec generate_talking_points_async(pos_integer(), [pos_integer()], pos_integer() | nil) ::
          {:ok, TalkingPointsGeneration.t()} | {:error, term()}
  @doc """
  Internal function to generate talking points for a list of product IDs.

  Returns:
  - `{:ok, generation}` on success
  - `{:error, reason}` on failure (empty list, invalid product IDs, etc.)
  """
  def generate_talking_points_async(brand_id, product_ids, product_set_id \\ nil)
      when is_integer(brand_id) and is_list(product_ids) do
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
          brand_id: brand_id,
          product_set_id: product_set_id,
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

  @spec get_generation(String.t()) :: TalkingPointsGeneration.t() | nil
  @doc """
  Gets the status of a talking points generation job.
  """
  def get_generation(job_id) when is_binary(job_id) do
    Repo.get_by(TalkingPointsGeneration, job_id: job_id)
  end

  @spec get_generation!(pos_integer()) :: TalkingPointsGeneration.t()
  @doc """
  Gets the status of a talking points generation by ID.
  """
  def get_generation!(id) do
    Repo.get!(TalkingPointsGeneration, id)
  end

  @spec list_product_set_generations(pos_integer()) :: [TalkingPointsGeneration.t()]
  @doc """
  Lists all talking points generations for a product set.
  """
  def list_product_set_generations(product_set_id) do
    TalkingPointsGeneration
    |> where([g], g.product_set_id == ^product_set_id)
    |> order_by([g], desc: g.inserted_at)
    |> Repo.all()
  end

  @spec create_generation(map()) ::
          {:ok, TalkingPointsGeneration.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Creates a new talking points generation record.
  """
  def create_generation(attrs) do
    attrs
    |> TalkingPointsGeneration.start_changeset()
    |> Repo.insert()
  end

  @spec update_generation(TalkingPointsGeneration.t(), map()) ::
          {:ok, TalkingPointsGeneration.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Updates a generation with new progress/results.
  """
  def update_generation(%TalkingPointsGeneration{} = generation, attrs) do
    generation
    |> TalkingPointsGeneration.progress_changeset(attrs)
    |> Repo.update()
  end

  @spec add_generation_result(TalkingPointsGeneration.t(), pos_integer(), String.t()) ::
          {:ok, TalkingPointsGeneration.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Adds a successful result for a product to the generation.
  """
  def add_generation_result(generation, product_id, talking_points) do
    generation
    |> TalkingPointsGeneration.add_result(product_id, talking_points)
    |> Repo.update()
  end

  @spec add_generation_error(TalkingPointsGeneration.t(), pos_integer(), String.t()) ::
          {:ok, TalkingPointsGeneration.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Adds an error for a product to the generation.
  """
  def add_generation_error(generation, product_id, error_message) do
    generation
    |> TalkingPointsGeneration.add_error(product_id, error_message)
    |> Repo.update()
  end

  @spec apply_generated_talking_points(TalkingPointsGeneration.t()) ::
          {:ok, [tuple()]} | {:error, :no_results}
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
      brand_id = generation.brand_id

      if is_nil(brand_id) do
        Logger.warning(
          "Generation #{generation.job_id} missing brand_id; falling back to unscoped product lookup"
        )
      end

      results =
        for {product_id_str, talking_points} <- generation.results do
          product_id = String.to_integer(product_id_str)

          with {:ok, product} <- fetch_product_for_generation(brand_id, product_id),
               {:ok, updated_product} <-
                 Catalog.update_product(product, %{talking_points_md: talking_points}) do
            Logger.debug("Applied talking points to product #{product_id}")
            {:ok, product_id, updated_product}
          else
            {:error, :not_found} ->
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
      brand_id: generation.brand_id,
      product_ids: generation.product_ids,
      product_set_id: generation.product_set_id
    }
    |> TalkingPointsWorker.new()
    |> Oban.insert()
  end

  @spec broadcast_generation_event(tuple()) :: :ok
  @doc """
  Broadcasts a generation event via PubSub.

  Events:
  - `{:generation_started, generation}`
  - `{:generation_progress, generation, product_id, product_name}`
  - `{:generation_completed, generation}`
  - `{:generation_failed, generation, reason}`
  """
  def broadcast_generation_event({event, generation} = message)
      when event in [:generation_started, :generation_completed, :generation_failed] do
    {general_topic, _job_topic} = topics_for_ids(generation.brand_id, generation.job_id)
    Phoenix.PubSub.broadcast(SocialObjects.PubSub, general_topic, message)
  end

  def broadcast_generation_event(
        {:generation_progress, generation, _product_id, _product_name} = message
      ) do
    {general_topic, job_topic} = topics_for_ids(generation.brand_id, generation.job_id)

    # Broadcast to general channel
    _ = Phoenix.PubSub.broadcast(SocialObjects.PubSub, general_topic, message)
    # Also broadcast to job-specific channel
    Phoenix.PubSub.broadcast(SocialObjects.PubSub, job_topic, message)
  end

  @spec subscribe() :: :ok
  @spec subscribe(String.t()) :: :ok
  @spec subscribe(pos_integer()) :: :ok
  @spec subscribe(pos_integer(), String.t()) :: :ok
  @doc """
  Subscribes to talking points generation events.

  ## Examples
      # Subscribe to all generation events
      AI.subscribe()

      # Subscribe to a specific job's events
      AI.subscribe("tp_abc123...")
  """
  def subscribe, do: subscribe_topic(nil, nil)

  def subscribe(job_id) when is_binary(job_id), do: subscribe_topic(nil, job_id)

  def subscribe(brand_id) when is_integer(brand_id), do: subscribe_topic(brand_id, nil)

  def subscribe(brand_id, job_id) when is_integer(brand_id) and is_binary(job_id),
    do: subscribe_topic(brand_id, job_id)

  defp subscribe_topic(brand_id, job_id) do
    {general_topic, job_topic} = topics_for_ids(brand_id, job_id)
    topic = if job_id, do: job_topic, else: general_topic
    Phoenix.PubSub.subscribe(SocialObjects.PubSub, topic)
  end

  defp fetch_product_for_generation(nil, product_id) do
    case Repo.get(Product, product_id) do
      nil -> {:error, :not_found}
      product -> {:ok, product}
    end
  end

  defp fetch_product_for_generation(brand_id, product_id) when is_integer(brand_id) do
    Catalog.get_product(brand_id, product_id)
  end

  defp topics_for_ids(nil, job_id) do
    general_topic = "ai:talking_points"
    job_topic = if job_id, do: "ai:talking_points:#{job_id}", else: general_topic
    {general_topic, job_topic}
  end

  defp topics_for_ids(brand_id, job_id) when is_integer(brand_id) do
    general_topic = "ai:talking_points:#{brand_id}"
    job_topic = if job_id, do: "ai:talking_points:#{brand_id}:#{job_id}", else: general_topic
    {general_topic, job_topic}
  end
end
