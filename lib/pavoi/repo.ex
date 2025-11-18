defmodule Pavoi.Repo do
  use Ecto.Repo,
    otp_app: :pavoi,
    adapter: Ecto.Adapters.Postgres
end
