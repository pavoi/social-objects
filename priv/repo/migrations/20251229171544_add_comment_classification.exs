defmodule Pavoi.Repo.Migrations.AddCommentClassification do
  use Ecto.Migration

  def change do
    # Create enum for sentiment
    execute(
      "CREATE TYPE comment_sentiment AS ENUM ('positive', 'neutral', 'negative')",
      "DROP TYPE comment_sentiment"
    )

    # Create enum for categories
    execute(
      """
      CREATE TYPE comment_category AS ENUM (
        'concern_complaint',
        'product_request',
        'question_confusion',
        'technical_issue',
        'praise_compliment',
        'general',
        'flash_sale'
      )
      """,
      "DROP TYPE comment_category"
    )

    alter table(:tiktok_comments) do
      add :sentiment, :comment_sentiment
      add :category, :comment_category
      add :classified_at, :utc_datetime
    end

    # Indexes for efficient aggregation queries
    create index(:tiktok_comments, [:stream_id, :sentiment])
    create index(:tiktok_comments, [:stream_id, :category])
  end
end
