defmodule Pavoi.AI.CommentClassifier do
  @moduledoc """
  Classifies TikTok live stream comments by sentiment and category using GPT-4o-mini.

  Uses batch processing to efficiently classify large numbers of comments while
  keeping API costs low.
  """

  require Logger

  alias OpenaiEx.Chat
  alias OpenaiEx.ChatMessage
  alias Pavoi.Repo
  alias Pavoi.TiktokLive.Comment

  import Ecto.Query, warn: false

  # Load classification prompt at compile time
  @prompt_path Path.join([__DIR__, "../../..", "priv", "prompts", "comment_classification.md"])
  @external_resource @prompt_path
  @classification_prompt File.read!(@prompt_path)

  # Configuration
  @batch_size 50
  @model "gpt-4o-mini"
  @temperature 0.1
  @max_tokens 2000
  @max_retries 3
  @initial_backoff_ms 1000

  # Mapping from abbreviated codes to atoms
  @sentiment_map %{"p" => :positive, "u" => :neutral, "n" => :negative}
  @category_map %{
    "cc" => :concern_complaint,
    "pr" => :product_request,
    "qc" => :question_confusion,
    "ti" => :technical_issue,
    "pc" => :praise_compliment,
    "g" => :general
  }

  # Fallback: if model puts category code in sentiment field, map to reasonable sentiment
  # This handles cases where the model returns s="qc" instead of s="u" for questions
  @category_to_sentiment_fallback %{
    "qc" => :neutral,
    "pr" => :neutral,
    "g" => :neutral,
    "ti" => :negative,
    "cc" => :negative,
    "pc" => :positive
  }

  @doc """
  Classifies all unclassified comments for a stream.

  First marks flash sale comments, then classifies remaining comments in batches.
  Returns `{:ok, %{classified: count, flash_sale: count}}` on success.

  ## Options
    - `:batch_size` - Number of comments per API call (default: #{@batch_size})
    - `:flash_sale_texts` - List of flash sale comment texts to mark (optional)
  """
  def classify_stream_comments(stream_id, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @batch_size)
    flash_sale_texts = Keyword.get(opts, :flash_sale_texts, [])

    # First, mark flash sale comments
    flash_sale_count = mark_flash_sale_comments(stream_id, flash_sale_texts)

    # Get unclassified comments (excluding flash sales now marked)
    comments = get_unclassified_comments(stream_id)

    Logger.info(
      "Classifying #{length(comments)} comments for stream ##{stream_id} " <>
        "(#{flash_sale_count} flash sales marked)"
    )

    # Process in batches
    results =
      comments
      |> Enum.chunk_every(batch_size)
      |> Enum.with_index(1)
      |> Enum.reduce({:ok, 0}, fn {batch, batch_num}, acc ->
        case acc do
          {:ok, count} ->
            total_batches = ceil(length(comments) / batch_size)
            Logger.debug("Processing batch #{batch_num}/#{total_batches}")

            case classify_and_save_batch(batch) do
              {:ok, batch_count} -> {:ok, count + batch_count}
              {:error, reason} -> {:error, reason}
            end

          error ->
            error
        end
      end)

    case results do
      {:ok, classified_count} ->
        Logger.info("Classified #{classified_count} comments for stream ##{stream_id}")
        {:ok, %{classified: classified_count, flash_sale: flash_sale_count}}

      {:error, reason} ->
        Logger.error("Failed to classify comments for stream ##{stream_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Classifies a batch of comments and saves results to the database.
  """
  def classify_and_save_batch(comments) do
    case classify_batch(comments) do
      {:ok, classifications} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        # Update each comment with classification
        updates =
          Enum.map(classifications, fn %{id: id, sentiment: sentiment, category: category} ->
            from(c in Comment,
              where: c.id == ^id,
              update: [
                set: [
                  sentiment: ^sentiment,
                  category: ^category,
                  classified_at: ^now
                ]
              ]
            )
            |> Repo.update_all([])
          end)

        {:ok, length(updates)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Classifies a batch of comments via the OpenAI API.

  Returns `{:ok, classifications}` where each classification is:
  `%{id: integer, sentiment: atom, category: atom}`
  """
  def classify_batch(comments, opts \\ []) do
    retries = Keyword.get(opts, :retries, @max_retries)
    attempt = Keyword.get(opts, :attempt, 1)

    case do_classify_batch(comments) do
      {:ok, classifications} ->
        {:ok, classifications}

      {:error, reason} = error ->
        if attempt < retries do
          backoff = calculate_backoff(attempt)

          Logger.warning(
            "Classification failed (attempt #{attempt}/#{retries}): #{inspect(reason)}. " <>
              "Retrying in #{backoff}ms..."
          )

          Process.sleep(backoff)
          classify_batch(comments, retries: retries, attempt: attempt + 1)
        else
          Logger.error("Classification failed after #{retries} attempts: #{inspect(reason)}")
          error
        end
    end
  end

  defp do_classify_batch(comments) do
    with {:ok, client} <- build_client(),
         {:ok, response} <- call_api(client, comments),
         {:ok, classifications} <- parse_response(response, comments) do
      {:ok, classifications}
    end
  end

  defp build_client do
    api_key = Application.get_env(:pavoi, :openai_api_key)

    if api_key && api_key != "" && api_key != "your_openai_api_key_here" do
      # Use longer timeout for batch classification (60 seconds)
      {:ok, OpenaiEx.new(api_key) |> OpenaiEx.with_receive_timeout(60_000)}
    else
      {:error, "OpenAI API key not configured"}
    end
  end

  defp call_api(client, comments) do
    # Format comments as JSON for the API
    comments_json =
      comments
      |> Enum.map(fn c ->
        %{
          id: c.id,
          text: c.comment_text,
          user: c.tiktok_nickname || c.tiktok_username || "anon"
        }
      end)
      |> Jason.encode!()

    chat_req =
      Chat.Completions.new(
        model: @model,
        messages: [
          ChatMessage.system(@classification_prompt),
          ChatMessage.user(comments_json)
        ],
        temperature: @temperature,
        max_tokens: @max_tokens
      )

    # Timeout is set on the client (60 seconds)
    case Chat.Completions.create(client, chat_req) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        {:error, "OpenAI API call failed: #{inspect(reason)}"}
    end
  rescue
    e ->
      {:error, "Exception during API call: #{Exception.message(e)}"}
  end

  defp parse_response(response, original_comments) do
    content =
      response
      |> get_in(["choices", Access.at(0), "message", "content"])
      |> String.trim()

    # Extract JSON from response (may be wrapped in markdown code block)
    json_content =
      case Regex.run(~r/```(?:json)?\s*([\s\S]*?)\s*```/, content) do
        [_, json] -> json
        nil -> content
      end

    case Jason.decode(json_content) do
      {:ok, classifications} when is_list(classifications) ->
        # Map abbreviated codes to atoms
        parsed =
          classifications
          |> Enum.map(&parse_classification/1)
          |> Enum.reject(&is_nil/1)

        # Accept partial success - as long as we got at least 50% valid classifications
        if length(parsed) >= length(original_comments) * 0.5 do
          {:ok, parsed}
        else
          {:error,
           "Only got #{length(parsed)}/#{length(original_comments)} valid classifications"}
        end

      {:ok, _} ->
        {:error, "Response is not a JSON array"}

      {:error, reason} ->
        {:error, "Failed to parse JSON: #{inspect(reason)}"}
    end
  end

  defp parse_classification(%{"id" => id, "s" => sentiment_code, "c" => category_code}) do
    # Try direct mapping first
    sentiment = Map.get(@sentiment_map, sentiment_code)
    category = Map.get(@category_map, category_code)

    # If sentiment is invalid but it's a category code, use fallback mapping
    sentiment =
      if sentiment do
        sentiment
      else
        fallback = Map.get(@category_to_sentiment_fallback, sentiment_code)

        if fallback do
          Logger.debug(
            "Using fallback sentiment mapping: s=#{sentiment_code} -> #{fallback}"
          )
        end

        fallback
      end

    if sentiment && category do
      %{id: id, sentiment: sentiment, category: category}
    else
      Logger.warning("Invalid classification codes: s=#{sentiment_code}, c=#{category_code}")
      nil
    end
  end

  defp parse_classification(invalid) do
    Logger.warning("Invalid classification format: #{inspect(invalid)}")
    nil
  end

  defp get_unclassified_comments(stream_id) do
    from(c in Comment,
      where: c.stream_id == ^stream_id,
      where: is_nil(c.classified_at),
      select: %{
        id: c.id,
        comment_text: c.comment_text,
        tiktok_username: c.tiktok_username,
        tiktok_nickname: c.tiktok_nickname
      },
      order_by: [asc: c.commented_at]
    )
    |> Repo.all()
  end

  defp mark_flash_sale_comments(_stream_id, []), do: 0

  defp mark_flash_sale_comments(stream_id, flash_sale_texts) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      from(c in Comment,
        where: c.stream_id == ^stream_id,
        where: c.comment_text in ^flash_sale_texts,
        where: is_nil(c.classified_at)
      )
      |> Repo.update_all(
        set: [
          sentiment: :neutral,
          category: :flash_sale,
          classified_at: now
        ]
      )

    count
  end

  defp calculate_backoff(attempt) do
    (@initial_backoff_ms * :math.pow(2, attempt - 1)) |> round()
  end
end
