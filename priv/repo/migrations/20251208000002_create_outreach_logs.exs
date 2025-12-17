defmodule Pavoi.Repo.Migrations.CreateOutreachLogs do
  use Ecto.Migration

  def change do
    create table(:outreach_logs) do
      add :creator_id, references(:creators, on_delete: :delete_all), null: false

      # Channel: "email" or "sms"
      add :channel, :string, null: false

      # Status: "sent", "failed", "bounced", "delivered"
      add :status, :string, null: false

      # Provider reference (SendGrid message ID or Twilio SID)
      add :provider_id, :string

      # Error details if failed
      add :error_message, :text

      # When the message was sent
      add :sent_at, :utc_datetime, null: false

      timestamps()
    end

    create index(:outreach_logs, [:creator_id])
    create index(:outreach_logs, [:channel])
    create index(:outreach_logs, [:status])
    create index(:outreach_logs, [:sent_at])
  end
end
