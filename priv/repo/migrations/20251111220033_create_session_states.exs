defmodule Pavoi.Repo.Migrations.CreateSessionStates do
  use Ecto.Migration

  def change do
    create table(:session_states) do
      add :session_id, references(:sessions, on_delete: :delete_all), null: false
      add :current_session_product_id, references(:session_products, on_delete: :nilify_all)
      add :current_image_index, :integer, null: false, default: 0
      add :updated_at, :utc_datetime, null: false
    end

    create unique_index(:session_states, [:session_id])
    create index(:session_states, [:current_session_product_id])
  end
end
