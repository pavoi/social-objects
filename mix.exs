defmodule Pavoi.MixProject do
  use Mix.Project

  def project do
    [
      app: :pavoi,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_apps: [:ex_unit]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Pavoi.Application, []},
      extra_applications: [:logger, :runtime_tools, :ex_aws]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.1"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:oban, "~> 2.19"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.26"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:nimble_csv, "~> 1.2"},

      # Pavoi-specific dependencies
      # Markdown rendering for talking points
      {:earmark, "~> 1.4"},
      # OpenAI API integration for AI-generated content
      {:openai_ex, "~> 0.9.18"},
      # Load .env files in development
      {:dotenvy, "~> 0.8.0", only: [:dev, :test]},
      # Static type analysis
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      # Static code analysis
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},

      # TikTok Live stream capture
      {:websockex, "~> 0.4.3"},
      {:protobuf, "~> 0.12.0"},

      # S3-compatible storage (Railway Buckets)
      {:ex_aws, "~> 2.5"},
      {:ex_aws_s3, "~> 2.5"},
      {:hackney, "~> 1.20"},
      {:sweet_xml, "~> 0.7"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["esbuild.install --if-missing"],
      "assets.build": ["compile", "esbuild pavoi", "assets.copy_vendor"],
      "assets.deploy": [
        "esbuild pavoi --minify",
        "assets.copy_vendor",
        "phx.digest"
      ],
      precommit: [
        "compile --warning-as-errors",
        "deps.unlock --unused",
        "format",
        "test",
        "credo --strict",
        "dialyzer"
      ]
    ]
  end
end
