defmodule Pavoi.Repo.Migrations.AddFollowsSharesToStreams do
  use Ecto.Migration

  def change do
    alter table(:tiktok_streams) do
      add :total_follows, :integer, default: 0
      add :total_shares, :integer, default: 0
    end

    alter table(:tiktok_stream_stats) do
      add :follow_count, :integer, default: 0
      add :share_count, :integer, default: 0
    end
  end
end
