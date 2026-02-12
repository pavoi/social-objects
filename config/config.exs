# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :social_objects, :scopes,
  user: [
    default: true,
    module: SocialObjects.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: SocialObjects.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :social_objects,
  ecto_repos: [SocialObjects.Repo],
  generators: [timestamp_type: :utc_datetime]

# Dev/test overrides (set via env vars in runtime.exs)
config :social_objects, :features, outreach_email_override: nil

# Default application name used in unauthenticated contexts
config :social_objects, :app_name, "Social Objects"

# Default brand slug for local/dev host-based resolution
config :social_objects, :default_brand_slug, "pavoi"

# Configures the endpoint
config :social_objects, SocialObjectsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SocialObjectsWeb.ErrorHTML, json: SocialObjectsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SocialObjects.PubSub,
  live_view: [signing_salt: "qaFml4h+"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :social_objects, SocialObjects.Mailer, adapter: Swoosh.Adapters.Local

# Store creator avatars in the bucket by default
config :social_objects, :creator_avatars, store_in_storage: true, store_locally: false

# Configure Oban background job processing
# Base configuration (applies to all environments)
config :social_objects, Oban,
  repo: SocialObjects.Repo,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    # Rescue jobs stuck in "executing" state after deploy/crash (check every 30s, rescue after 60s)
    {Oban.Plugins.Lifeline, rescue_after: :timer.seconds(60)}
  ],
  queues: [
    default: 10,
    shopify: 5,
    tiktok: 5,
    creators: 5,
    bigquery: 3,
    enrichment: 2,
    slack: 3,
    analytics: 3
  ]

# TikTok Live stream capture configuration
config :social_objects, :tiktok_live_monitor, accounts: []

# Worker tuning defaults (can be overridden per environment)
config :social_objects, :worker_tuning,
  creator_enrichment: [
    batch_size: 75,
    api_delay_ms: 300,
    rate_limit_max_consecutive: 3,
    rate_limit_initial_backoff_seconds: 15 * 60,
    rate_limit_max_backoff_seconds: 2 * 60 * 60,
    rate_limit_cooldown_seconds: 10 * 60
  ],
  tiktok_sync: [page_size: 50],
  product_performance_sync: [page_size: 100],
  video_sync: [page_size: 100, thumbnail_api_delay_ms: 100]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  social_objects: [
    args:
      ~w(js/app.js js/workers/whisper_worker.js --bundle --target=es2022 --outdir=../priv/static/assets/js --format=esm --splitting --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Tailwind CSS (standalone CLI - no Node.js required)
config :tailwind,
  version: "4.0.14",
  social_objects: [
    args: ~w(
      --input=css/tailwind.css
      --output=../priv/static/assets/css/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
