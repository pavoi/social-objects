defmodule Pavoi.Repo.Migrations.AddSentimentAnalysisToStreams do
  use Ecto.Migration

  def change do
    alter table(:tiktok_streams) do
      add :sentiment_analysis, :text
    end
  end
end
