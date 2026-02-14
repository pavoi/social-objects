defmodule SocialObjects.Types do
  @moduledoc """
  Shared type definitions for SocialObjects contexts.

  This module provides reusable type definitions to ensure consistency
  across all context modules and enable better Dialyzer analysis.
  """

  # IDs
  @type id :: pos_integer()
  @type brand_id :: pos_integer()
  @type creator_id :: pos_integer()
  @type product_id :: pos_integer()
  @type user_id :: pos_integer()

  # Result tuples
  @type result(success) :: {:ok, success} | {:error, term()}
  @type db_result(schema) :: {:ok, schema} | {:error, Ecto.Changeset.t()}

  # Pagination
  @type pagination_opts :: keyword()
  @type paginated_result(item) :: %{
          required(:items) => [item],
          required(:total) => non_neg_integer(),
          required(:page) => pos_integer(),
          required(:per_page) => pos_integer(),
          required(:has_more) => boolean()
        }

  # Common option types
  @type sort_direction :: :asc | :desc
  @type date_range :: %{from: Date.t(), to: Date.t()}
end
