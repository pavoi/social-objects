defmodule SocialObjectsWeb.ParamHelpers do
  @moduledoc """
  Safe parameter parsing helpers that won't crash on invalid input.

  Use these instead of `String.to_integer/1` when parsing user-provided
  URL parameters, form inputs, or event payloads to prevent crashes from
  malformed input.

  ## Examples

      # In mount/3 - redirect on invalid param
      def mount(%{"id" => id}, _session, socket) do
        case parse_id(id) do
          {:ok, id} -> {:ok, assign(socket, :id, id)}
          :error -> {:ok, push_navigate(socket, to: ~p"/") |> put_flash(:error, "Invalid ID")}
        end
      end

      # In handle_event/3 - return error to client
      def handle_event("select", %{"id" => id}, socket) do
        case parse_id(id) do
          {:ok, id} -> {:noreply, do_select(socket, id)}
          :error -> {:reply, %{error: "Invalid ID"}, socket}
        end
      end

      # For optional params
      def handle_params(params, _uri, socket) do
        page = parse_id_or_default(params["page"], 1)
        {:noreply, assign(socket, :page, page)}
      end
  """

  @doc """
  Safely parses a value to a positive integer ID.

  Returns `{:ok, integer}` for valid positive integers, `:error` otherwise.

  ## Examples

      iex> parse_id("123")
      {:ok, 123}

      iex> parse_id("abc")
      :error

      iex> parse_id("-5")
      :error

      iex> parse_id(nil)
      :error
  """
  @spec parse_id(any()) :: {:ok, pos_integer()} | :error
  def parse_id(value) when is_integer(value) and value > 0, do: {:ok, value}
  def parse_id(nil), do: :error
  def parse_id(""), do: :error

  def parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> :error
    end
  end

  def parse_id(_), do: :error

  @doc """
  Safely parses a value to an integer (including zero and negatives).

  Returns `{:ok, integer}` for valid integers, `:error` otherwise.

  ## Examples

      iex> parse_integer("123")
      {:ok, 123}

      iex> parse_integer("-5")
      {:ok, -5}

      iex> parse_integer("0")
      {:ok, 0}

      iex> parse_integer("abc")
      :error
  """
  @spec parse_integer(any()) :: {:ok, integer()} | :error
  def parse_integer(value) when is_integer(value), do: {:ok, value}
  def parse_integer(nil), do: :error
  def parse_integer(""), do: :error

  def parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  def parse_integer(_), do: :error

  @doc """
  Parses an integer or returns the default value on failure.

  Useful for optional parameters like pagination.

  ## Examples

      iex> parse_id_or_default("5", 1)
      5

      iex> parse_id_or_default(nil, 1)
      1

      iex> parse_id_or_default("invalid", 1)
      1
  """
  @spec parse_id_or_default(any(), integer()) :: integer()
  def parse_id_or_default(value, default) when is_integer(default) do
    case parse_id(value) do
      {:ok, int} -> int
      :error -> default
    end
  end

  @doc """
  Parses an integer or returns nil on failure.

  Useful for optional filter parameters.

  ## Examples

      iex> parse_id_or_nil("5")
      5

      iex> parse_id_or_nil(nil)
      nil

      iex> parse_id_or_nil("invalid")
      nil
  """
  @spec parse_id_or_nil(any()) :: pos_integer() | nil
  def parse_id_or_nil(value) do
    case parse_id(value) do
      {:ok, int} -> int
      :error -> nil
    end
  end

  @doc """
  Parses an integer (including zero/negatives) or returns nil on failure.

  ## Examples

      iex> parse_integer_or_nil("0")
      0

      iex> parse_integer_or_nil("-5")
      -5

      iex> parse_integer_or_nil("invalid")
      nil
  """
  @spec parse_integer_or_nil(any()) :: integer() | nil
  def parse_integer_or_nil(value) do
    case parse_integer(value) do
      {:ok, int} -> int
      :error -> nil
    end
  end

  @doc """
  Parses an integer (including zero/negatives) or returns the default on failure.

  ## Examples

      iex> parse_integer_or_default("0", 1)
      0

      iex> parse_integer_or_default("invalid", 1)
      1
  """
  @spec parse_integer_or_default(any(), integer()) :: integer()
  def parse_integer_or_default(value, default) when is_integer(default) do
    case parse_integer(value) do
      {:ok, int} -> int
      :error -> default
    end
  end
end
