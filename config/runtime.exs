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

# Shopify configuration for development (after .env is loaded)
if config_env() == :dev do
  config :hudson,
    shopify_access_token: System.get_env("SHOPIFY_ACCESS_TOKEN"),
    shopify_store_name: System.get_env("SHOPIFY_STORE_NAME"),
    openai_api_key: System.get_env("OPENAI_API_KEY")

  # OpenAI client configuration
  config :hudson, Hudson.AI.OpenAIClient,
    model: System.get_env("OPENAI_MODEL", "gpt-4o-mini"),
    temperature: String.to_float(System.get_env("OPENAI_TEMPERATURE", "0.7")),
    max_tokens: String.to_integer(System.get_env("OPENAI_MAX_TOKENS", "500")),
    max_retries: String.to_integer(System.get_env("OPENAI_MAX_RETRIES", "3")),
    initial_backoff_ms: String.to_integer(System.get_env("OPENAI_INITIAL_BACKOFF_MS", "1000"))
end

local_db_path =
  case config_env() do
    :test ->
      Path.join(System.tmp_dir!(), "hudson_local_test.db")

    _ ->
      Hudson.Desktop.Bootstrap.ensure_data_dir!()
      Hudson.Desktop.Bootstrap.local_db_path()
  end

config :hudson, Hudson.LocalRepo,
  database: local_db_path,
  pool_size: 5,
  journal_mode: :wal,
  stacktrace: config_env() != :prod

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/hudson start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :hudson, HudsonWeb.Endpoint, server: true
end

if config_env() == :prod do
  host = System.get_env("PHX_HOST") || "127.0.0.1"

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  port =
    case System.get_env("PORT") do
      nil ->
        chosen = Hudson.Desktop.Bootstrap.pick_ephemeral_port()
        Hudson.Desktop.Bootstrap.write_handshake!(chosen)
        chosen

      port_str ->
        chosen = String.to_integer(port_str)
        Hudson.Desktop.Bootstrap.write_handshake!(chosen)
        chosen
    end

  database_url = Hudson.Desktop.Bootstrap.database_url()
  secret_key_base = Hudson.Desktop.Bootstrap.ensure_secret_key_base()

  config :hudson, Hudson.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  config :hudson, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Shopify configuration
  config :hudson,
    neon_enabled: System.get_env("HUDSON_ENABLE_NEON", "true") in ["true", "1", "yes"],
    shopify_access_token: System.get_env("SHOPIFY_ACCESS_TOKEN"),
    shopify_store_name: System.get_env("SHOPIFY_STORE_NAME"),
    openai_api_key: System.get_env("OPENAI_API_KEY")

  # OpenAI client configuration
  config :hudson, Hudson.AI.OpenAIClient,
    model: System.get_env("OPENAI_MODEL", "gpt-4o-mini"),
    temperature: String.to_float(System.get_env("OPENAI_TEMPERATURE", "0.7")),
    max_tokens: String.to_integer(System.get_env("OPENAI_MAX_TOKENS", "500")),
    max_retries: String.to_integer(System.get_env("OPENAI_MAX_RETRIES", "3")),
    initial_backoff_ms: String.to_integer(System.get_env("OPENAI_INITIAL_BACKOFF_MS", "1000"))

  config :hudson, HudsonWeb.Endpoint,
    server: true,
    url: [host: host, port: port, scheme: "http"],
    http: [
      ip: {127, 0, 0, 1},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :hudson, HudsonWeb.Endpoint,
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
  #     config :hudson, HudsonWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :hudson, Hudson.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
