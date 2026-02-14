defmodule SocialObjects.Workers.TalkingPointsWorker do
  @moduledoc """
  Oban worker that generates AI-powered talking points for products.

  Processes single products or batches of products from a product set, using
  OpenAI's API to generate TikTok livestream-optimized talking points.

  ## Features
  - Automatic retry with exponential backoff (3 attempts)
  - Real-time progress broadcasting via PubSub
  - Preserves partial results on failure
  - Applies generated talking points to product records

  ## Job Arguments
  - `job_id` - Unique identifier for tracking this generation
  - `product_ids` - List of product IDs to process
  - `product_set_id` - Optional product set ID (for batch operations)
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  import Ecto.Query, warn: false
  require Logger

  alias SocialObjects.AI
  alias SocialObjects.AI.OpenAIClient
  alias SocialObjects.Catalog.Product
  alias SocialObjects.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"job_id" => job_id, "product_ids" => product_ids} = args}) do
    product_set_id = Map.get(args, "product_set_id")

    Logger.info("""
    Starting talking points generation:
    - Job ID: #{job_id}
    - Products: #{length(product_ids)}
    - Product Set: #{product_set_id || "N/A"}
    """)

    # Get the generation record
    generation = AI.get_generation(job_id)

    if generation do
      # Update status to processing
      {:ok, generation} = AI.update_generation(generation, %{status: "processing"})

      # Broadcast that we've started
      AI.broadcast_generation_event({:generation_started, generation})

      if is_nil(generation.brand_id) do
        Logger.warning(
          "Generation #{generation.job_id} missing brand_id; product lookups will be unscoped"
        )
      end

      # Process each product
      _results = process_products(generation, product_ids)

      # Reload generation to get final status
      generation = AI.get_generation!(generation.id)

      # Apply the generated talking points to the products
      _ =
        if generation.completed_count > 0 do
          AI.apply_generated_talking_points(generation)
        end

      # Broadcast completion
      AI.broadcast_generation_event({:generation_completed, generation})

      Logger.info("""
      Talking points generation completed:
      - Job ID: #{job_id}
      - Succeeded: #{generation.completed_count}/#{generation.total_count}
      - Failed: #{generation.failed_count}
      """)

      # Return :ok if any succeeded, or error if all failed
      if generation.completed_count > 0 do
        :ok
      else
        {:error, "All products failed to generate"}
      end
    else
      Logger.error("Generation record not found for job_id: #{job_id}")
      {:error, "Generation record not found"}
    end
  end

  defp process_products(generation, product_ids) do
    total = length(product_ids)

    {_final_generation, results} =
      product_ids
      |> Enum.with_index(1)
      |> Enum.reduce({generation, []}, fn {product_id, index}, {current_gen, acc_results} ->
        result = process_product(current_gen, product_id, index, total)

        # Get the updated generation after processing
        updated_gen = AI.get_generation!(current_gen.id)

        {updated_gen, [result | acc_results]}
      end)

    Enum.reverse(results)
  end

  defp process_product(generation, product_id, index, total) do
    Logger.info("Processing product #{index}/#{total} (ID: #{product_id})")

    try do
      # Get product details
      product =
        generation
        |> fetch_product(product_id)
        |> Repo.preload(:brand)

      # Broadcast progress
      AI.broadcast_generation_event({
        :generation_progress,
        generation,
        product_id,
        product.name
      })

      # Build product map for OpenAI
      product_data = %{
        name: product.name,
        description: product.description,
        original_price_cents: product.original_price_cents,
        sale_price_cents: product.sale_price_cents,
        brand_name: if(product.brand, do: product.brand.name, else: nil)
      }

      # Generate talking points with retry logic built into OpenAIClient
      case OpenAIClient.generate_talking_points(product_data) do
        {:ok, talking_points} ->
          Logger.info("Successfully generated talking points for product #{product_id}")

          # Save the result (generation will be reloaded in the reduce loop)
          {:ok, _updated_generation} =
            AI.add_generation_result(generation, product_id, talking_points)

          {:ok, product_id, talking_points}

        {:error, reason} ->
          error_message = format_error(reason)

          Logger.error(
            "Failed to generate talking points for product #{product_id}: #{error_message}"
          )

          # Save the error (generation will be reloaded in the reduce loop)
          {:ok, _updated_generation} =
            AI.add_generation_error(generation, product_id, error_message)

          {:error, product_id, error_message}
      end
    rescue
      e ->
        error_message = "Exception: #{Exception.message(e)}"
        Logger.error("Exception while processing product #{product_id}: #{error_message}")

        # Save the error (generation will be reloaded in the reduce loop)
        {:ok, _updated_generation} =
          AI.add_generation_error(generation, product_id, error_message)

        {:error, product_id, error_message}
    end
  end

  defp format_error(reason), do: to_string(reason)

  defp fetch_product(%{brand_id: nil}, product_id) do
    Repo.get!(Product, product_id)
  end

  defp fetch_product(%{brand_id: brand_id}, product_id) when is_integer(brand_id) do
    Product
    |> where([p], p.id == ^product_id and p.brand_id == ^brand_id)
    |> Repo.one!()
  end
end
