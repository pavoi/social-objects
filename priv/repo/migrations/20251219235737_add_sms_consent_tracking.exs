defmodule Pavoi.Repo.Migrations.AddSmsConsentTracking do
  use Ecto.Migration

  def change do
    # Add consent tracking fields to creators table
    alter table(:creators) do
      add :sms_consent_ip, :string
      add :sms_consent_user_agent, :text
    end

    # Add lark_preset to outreach_logs to track which preset was used
    alter table(:outreach_logs) do
      add :lark_preset, :string
    end
  end
end
