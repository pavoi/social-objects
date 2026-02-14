defmodule SocialObjects.ErrorConventions do
  @moduledoc """
  Error handling conventions for the SocialObjects codebase.

  This module documents the recommended patterns for error handling.
  It exists primarily as documentation and reference - it does not need
  to be imported or used directly.

  ## Error Return Types

  The codebase uses three main error patterns:

  ### 1. Domain Errors - Use atoms

  For errors that represent known domain conditions:

      {:error, :not_found}
      {:error, :unauthorized}
      {:error, :invalid_position}
      {:error, :already_exists}
      {:error, :rate_limited}

  These are best for:
  - Conditions the caller is expected to handle
  - Errors that can be pattern matched
  - Domain-specific failure modes

  ### 2. Validation Errors - Use Ecto changesets

  For form/input validation errors, return the changeset directly:

      {:error, %Ecto.Changeset{}}

  Callers can use `Ecto.Changeset.traverse_errors/2` to format messages.
  LiveViews can pass changesets directly to forms with `to_form/1`.

  ### 3. External Service Errors - Use strings or structs

  For errors from external APIs (OpenAI, TikTok, etc.):

      # Simple string message
      {:error, "OpenAI API call failed: rate limited"}

      # Or structured error (preferred for complex cases)
      {:error, %ServiceError{
        service: :openai,
        message: "Rate limited",
        code: 429,
        retryable: true
      }}

  ## Rescue Clause Guidelines

  ### DO: Catch specific, expected exceptions

      rescue
        e in [Req.Error, Jason.DecodeError, ArgumentError] ->
          {:error, "API call failed: \#{Exception.message(e)}"}

  ### DON'T: Use bare rescue

      # BAD - catches everything including OOM, system errors
      rescue
        e ->
          {:error, e}

  ## Error Propagation

  ### DO: Propagate errors up the call stack

      case external_service_call() do
        {:ok, result} -> process(result)
        {:error, reason} -> {:error, reason}  # Let caller decide how to handle
      end

  ### DON'T: Silently swallow errors

      # BAD - caller has no idea something failed
      case external_service_call() do
        {:ok, result} -> result
        {:error, _} -> nil
      end

  ## LiveView Error Handling

  For LiveView event handlers, return appropriate error feedback:

      def handle_event("action", params, socket) do
        case do_action(params) do
          {:ok, result} ->
            {:noreply, assign(socket, :result, result)}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Item not found")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, :form, to_form(changeset))}
        end
      end

  ## Worker/Background Job Error Handling

  For Oban workers, errors should be explicit to enable proper retry behavior:

      def perform(%{args: args}) do
        case process(args) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}  # Oban will retry
        end
      end

  Raising exceptions will also trigger retries with snooze/backoff.
  """

  # This module is documentation-only.
  # No functions are implemented here.
end
