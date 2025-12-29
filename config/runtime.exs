import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# Load .env file for development
if config_env() == :dev and File.exists?(".env") and Code.ensure_loaded?(Dotenvy) do
  Dotenvy.source!([".env"], side_effect: &System.put_env/1)
end

# Feature flags (read from environment variables, applies to all environments)
# Must be after Dotenvy loads .env in dev
config :pavoi, :features,
  voice_control_enabled: System.get_env("VOICE_CONTROL_ENABLED", "true") == "true",
  outreach_email_enabled: System.get_env("OUTREACH_EMAIL_ENABLED", "true") == "true",
  outreach_email_override: System.get_env("OUTREACH_EMAIL_OVERRIDE")

# Shopify configuration for development (after .env is loaded)
# Note: SHOPIFY_ACCESS_TOKEN is NOT needed here - tokens are generated dynamically
# using client credentials grant. See lib/pavoi/shopify/auth.ex for details.
if config_env() == :dev do
  config :pavoi,
    shopify_client_id: System.get_env("SHOPIFY_CLIENT_ID"),
    shopify_client_secret: System.get_env("SHOPIFY_CLIENT_SECRET"),
    shopify_store_name: System.get_env("SHOPIFY_STORE_NAME"),
    openai_api_key: System.get_env("OPENAI_API_KEY"),
    # BigQuery configuration for Creator CRM sync
    bigquery_project_id: System.get_env("BIGQUERY_PROJECT_ID"),
    bigquery_service_account_email: System.get_env("BIGQUERY_SERVICE_ACCOUNT_EMAIL"),
    bigquery_private_key: System.get_env("BIGQUERY_PRIVATE_KEY"),
    # SendGrid configuration for creator outreach emails
    sendgrid_api_key: System.get_env("SENDGRID_API_KEY"),
    sendgrid_from_email: System.get_env("SENDGRID_FROM_EMAIL"),
    sendgrid_from_name: System.get_env("SENDGRID_FROM_NAME", "Pavoi"),
    # Twilio configuration for creator outreach SMS
    twilio_account_sid: System.get_env("TWILIO_ACCOUNT_SID"),
    twilio_auth_token: System.get_env("TWILIO_AUTH_TOKEN"),
    twilio_from_number: System.get_env("TWILIO_FROM_NUMBER"),
    # TikTok Bridge service URL for TikTok Live capture
    tiktok_bridge_url: System.get_env("TIKTOK_BRIDGE_URL", "http://localhost:8080"),
    # Slack configuration for stream reports
    slack_bot_token: System.get_env("SLACK_BOT_TOKEN"),
    slack_channel: System.get_env("SLACK_CHANNEL", "#tiktok-live-reports"),
    slack_dev_user_id: System.get_env("SLACK_DEV_USER_ID")

  # OpenAI client configuration
  config :pavoi, Pavoi.AI.OpenAIClient,
    model: System.get_env("OPENAI_MODEL", "gpt-4o-mini"),
    temperature: String.to_float(System.get_env("OPENAI_TEMPERATURE", "0.7")),
    max_tokens: String.to_integer(System.get_env("OPENAI_MAX_TOKENS", "500")),
    max_retries: String.to_integer(System.get_env("OPENAI_MAX_RETRIES", "3")),
    initial_backoff_ms: String.to_integer(System.get_env("OPENAI_INITIAL_BACKOFF_MS", "1000"))
end

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/pavoi start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :pavoi, PavoiWeb.Endpoint, server: true
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :pavoi, Pavoi.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :pavoi, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Shopify configuration
  # Note: SHOPIFY_ACCESS_TOKEN is NOT needed - tokens are generated dynamically
  # using client credentials grant. See lib/pavoi/shopify/auth.ex for details.
  config :pavoi,
    shopify_client_id: System.get_env("SHOPIFY_CLIENT_ID"),
    shopify_client_secret: System.get_env("SHOPIFY_CLIENT_SECRET"),
    shopify_store_name: System.get_env("SHOPIFY_STORE_NAME"),
    openai_api_key: System.get_env("OPENAI_API_KEY"),
    # BigQuery configuration for Creator CRM sync
    bigquery_project_id: System.get_env("BIGQUERY_PROJECT_ID"),
    bigquery_service_account_email: System.get_env("BIGQUERY_SERVICE_ACCOUNT_EMAIL"),
    bigquery_private_key: System.get_env("BIGQUERY_PRIVATE_KEY"),
    # SendGrid configuration for creator outreach emails
    sendgrid_api_key: System.get_env("SENDGRID_API_KEY"),
    sendgrid_from_email: System.get_env("SENDGRID_FROM_EMAIL"),
    sendgrid_from_name: System.get_env("SENDGRID_FROM_NAME", "Pavoi"),
    # Twilio configuration for creator outreach SMS
    twilio_account_sid: System.get_env("TWILIO_ACCOUNT_SID"),
    twilio_auth_token: System.get_env("TWILIO_AUTH_TOKEN"),
    twilio_from_number: System.get_env("TWILIO_FROM_NUMBER"),
    # TikTok Bridge service URL for TikTok Live capture
    tiktok_bridge_url: System.get_env("TIKTOK_BRIDGE_URL", "http://localhost:8080"),
    # Slack configuration for stream reports
    slack_bot_token: System.get_env("SLACK_BOT_TOKEN"),
    slack_channel: System.get_env("SLACK_CHANNEL", "#tiktok-live-reports")

  # OpenAI client configuration
  config :pavoi, Pavoi.AI.OpenAIClient,
    model: System.get_env("OPENAI_MODEL", "gpt-4o-mini"),
    temperature: String.to_float(System.get_env("OPENAI_TEMPERATURE", "0.7")),
    max_tokens: String.to_integer(System.get_env("OPENAI_MAX_TOKENS", "500")),
    max_retries: String.to_integer(System.get_env("OPENAI_MAX_RETRIES", "3")),
    initial_backoff_ms: String.to_integer(System.get_env("OPENAI_INITIAL_BACKOFF_MS", "1000"))

  config :pavoi, PavoiWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    check_origin: ["https://#{host}", "https://app.pavoi.com"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :pavoi, PavoiWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :pavoi, PavoiWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # Configure Swoosh Mailer with SendGrid adapter for production
  config :pavoi, Pavoi.Mailer,
    adapter: Swoosh.Adapters.Sendgrid,
    api_key: System.get_env("SENDGRID_API_KEY")
end
