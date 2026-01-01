defmodule Pavoi.Repo.Migrations.AddEmailOptOutToCreators do
  use Ecto.Migration

  def change do
    alter table(:creators) do
      add :email_opted_out, :boolean, default: false, null: false
      add :email_opted_out_at, :utc_datetime
      add :email_opted_out_reason, :string
    end

    create index(:creators, [:email_opted_out])

    # Migrate existing data: mark unsubscribed creators as opted out
    execute """
              UPDATE creators
              SET email_opted_out = true,
                  email_opted_out_reason = 'unsubscribe',
                  email_opted_out_at = NOW()
              WHERE outreach_status = 'unsubscribed'
            """,
            """
              UPDATE creators
              SET email_opted_out = false,
                  email_opted_out_reason = NULL,
                  email_opted_out_at = NULL
              WHERE email_opted_out = true AND outreach_status = 'unsubscribed'
            """

    # Also mark creators who have spam reports or unsubscribes in outreach_logs
    execute """
              UPDATE creators c
              SET email_opted_out = true,
                  email_opted_out_reason = CASE
                    WHEN EXISTS (
                      SELECT 1 FROM outreach_logs ol
                      WHERE ol.creator_id = c.id AND ol.spam_reported_at IS NOT NULL
                    ) THEN 'spam_report'
                    ELSE 'unsubscribe'
                  END,
                  email_opted_out_at = COALESCE(
                    (SELECT GREATEST(ol.unsubscribed_at, ol.spam_reported_at)
                     FROM outreach_logs ol
                     WHERE ol.creator_id = c.id
                       AND (ol.unsubscribed_at IS NOT NULL OR ol.spam_reported_at IS NOT NULL)
                     ORDER BY GREATEST(ol.unsubscribed_at, ol.spam_reported_at) DESC
                     LIMIT 1),
                    NOW()
                  )
              WHERE c.email_opted_out = false
                AND EXISTS (
                  SELECT 1 FROM outreach_logs ol
                  WHERE ol.creator_id = c.id
                    AND (ol.unsubscribed_at IS NOT NULL OR ol.spam_reported_at IS NOT NULL)
                )
            """,
            # No rollback for this - data migration is one-way
            ""
  end
end
