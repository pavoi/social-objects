defmodule Pavoi.AI.OpenAIClient do
  @moduledoc """
  Client for interacting with OpenAI API using the openai_ex library.
  Handles talking points generation with retry logic and error handling.
  """

  require Logger

  alias OpenaiEx.Chat
  alias OpenaiEx.ChatMessage

  # Load system prompt at compile time for better performance
  @prompt_path Path.join([__DIR__, "../../..", "priv", "prompts", "talking_points_system.md"])
  @external_resource @prompt_path
  @system_prompt File.read!(@prompt_path)

  # Configuration getters - these read from application environment
  defp config, do: Application.get_env(:pavoi, __MODULE__, [])
  defp model, do: Keyword.get(config(), :model, "gpt-4o-mini")
  defp temperature, do: Keyword.get(config(), :temperature, 0.7)
  defp max_tokens, do: Keyword.get(config(), :max_tokens, 500)
  defp max_retries, do: Keyword.get(config(), :max_retries, 3)
  defp initial_backoff_ms, do: Keyword.get(config(), :initial_backoff_ms, 1000)

  @doc """
  Generates talking points for a product using OpenAI's chat completion API.

  Returns `{:ok, talking_points}` on success or `{:error, reason}` on failure.

  ## Parameters
    - product: Map containing product details (name, description, price, etc.)

  ## Example
      iex> product = %{name: "Gold Necklace", description: "Beautiful 18k gold...", ...}
      iex> OpenAIClient.generate_talking_points(product)
      {:ok, "- Stunning 18k gold...\\n- Perfect for..."}
  """
  def generate_talking_points(product, opts \\ []) do
    retries = Keyword.get(opts, :retries, max_retries())
    attempt = Keyword.get(opts, :attempt, 1)

    case do_generate_talking_points(product) do
      {:ok, talking_points} ->
        {:ok, talking_points}

      {:error, reason} = error ->
        if attempt < retries do
          backoff = calculate_backoff(attempt)

          Logger.warning(
            "OpenAI API call failed (attempt #{attempt}/#{retries}): #{inspect(reason)}. " <>
              "Retrying in #{backoff}ms..."
          )

          Process.sleep(backoff)
          generate_talking_points(product, retries: retries, attempt: attempt + 1)
        else
          Logger.error("OpenAI API call failed after #{retries} attempts: #{inspect(reason)}")

          error
        end
    end
  end

  defp do_generate_talking_points(product) do
    with {:ok, system_prompt} <- load_system_prompt(),
         {:ok, user_prompt} <- build_user_prompt(product),
         {:ok, openai} <- build_client(),
         {:ok, response} <- call_openai(openai, system_prompt, user_prompt) do
      {:ok, extract_content(response)}
    end
  end

  @doc """
  Returns the system prompt (loaded at compile time for performance).
  """
  def load_system_prompt do
    {:ok, @system_prompt}
  end

  @doc """
  Builds the user prompt with product details.
  """
  def build_user_prompt(product) do
    # Format price information
    price_info =
      cond do
        product[:sale_price_cents] && product[:original_price_cents] &&
            product[:sale_price_cents] < product[:original_price_cents] ->
          original = format_price(product.original_price_cents)
          sale = format_price(product.sale_price_cents)
          "Price: Original #{original}, Sale #{sale}"

        product[:original_price_cents] ->
          "Price: #{format_price(product.original_price_cents)}"

        true ->
          nil
      end

    # Build the prompt
    prompt_parts = [
      "Product: #{product[:name] || "Unknown Product"}",
      if(product[:description], do: "Description: #{product[:description]}", else: nil),
      price_info,
      if(product[:brand_name], do: "Brand: #{product[:brand_name]}", else: nil)
    ]

    prompt =
      prompt_parts
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    {:ok, prompt}
  end

  defp format_price(nil), do: "N/A"

  defp format_price(cents) when is_integer(cents) do
    dollars = cents / 100
    "$#{:erlang.float_to_binary(dollars, decimals: 2)}"
  end

  @doc """
  Builds the OpenAI client with API key from configuration.
  """
  def build_client do
    api_key = Application.get_env(:pavoi, :openai_api_key)

    if api_key && api_key != "" && api_key != "your_openai_api_key_here" do
      {:ok, OpenaiEx.new(api_key)}
    else
      {:error, "OpenAI API key not configured"}
    end
  end

  @doc """
  Calls the OpenAI API with the given prompts.
  """
  def call_openai(client, system_prompt, user_prompt) do
    chat_req =
      Chat.Completions.new(
        model: model(),
        messages: [
          ChatMessage.system(system_prompt),
          ChatMessage.user(user_prompt)
        ],
        temperature: temperature(),
        max_tokens: max_tokens()
      )

    case Chat.Completions.create(client, chat_req) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        {:error, "OpenAI API call failed: #{inspect(reason)}"}
    end
  rescue
    e ->
      {:error, "Exception during OpenAI API call: #{Exception.message(e)}"}
  end

  @doc """
  Extracts the content from the OpenAI response.
  """
  def extract_content(response) do
    response
    |> get_in(["choices", Access.at(0), "message", "content"])
    |> String.trim()
  end

  @doc """
  Calculates exponential backoff delay in milliseconds.
  """
  def calculate_backoff(attempt) do
    (initial_backoff_ms() * :math.pow(2, attempt - 1)) |> round()
  end
end
