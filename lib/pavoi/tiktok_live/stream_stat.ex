defmodule Pavoi.TiktokLive.StreamStat do
  @moduledoc """
  Time-series statistics captured during a TikTok live stream.

  Stats are sampled periodically (typically every 30 seconds) to track
  engagement metrics over the course of the stream.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "tiktok_stream_stats" do
    field :recorded_at, :utc_datetime
    field :viewer_count, :integer, default: 0
    field :like_count, :integer, default: 0
    field :gift_count, :integer, default: 0
    field :comment_count, :integer, default: 0
    field :follow_count, :integer, default: 0
    field :share_count, :integer, default: 0

    belongs_to :stream, Pavoi.TiktokLive.Stream

    timestamps()
  end

  @doc false
  def changeset(stat, attrs) do
    stat
    |> cast(attrs, [
      :stream_id,
      :recorded_at,
      :viewer_count,
      :like_count,
      :gift_count,
      :comment_count,
      :follow_count,
      :share_count
    ])
    |> validate_required([:stream_id, :recorded_at])
    |> foreign_key_constraint(:stream_id)
  end
end
