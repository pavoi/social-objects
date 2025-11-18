defmodule Pavoi.Repo.Migrations.AddHostMessagesToSessionStates do
  use Ecto.Migration

  def change do
    alter table(:session_states) do
      add :current_host_message_text, :text
      add :current_host_message_id, :string
      add :current_host_message_timestamp, :utc_datetime
    end
  end
end
