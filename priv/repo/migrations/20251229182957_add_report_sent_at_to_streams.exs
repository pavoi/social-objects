defmodule Pavoi.Repo.Migrations.AddReportSentAtToStreams do
  use Ecto.Migration

  def change do
    alter table(:tiktok_streams) do
      add :report_sent_at, :utc_datetime
    end
  end
end
