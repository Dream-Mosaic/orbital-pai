# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :app,
  ecto_repos: [App.Repo],
  generators: [timestamp_type: :utc_datetime]

# Reminder times (and any other local-tz display) shift from stored UTC via this database.
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

# SQLite: WAL so the hot read path and the writer (turn insert + memory updater)
# don't block each other; busy_timeout retries brief writer contention.
config :app, App.Repo,
  journal_mode: :wal,
  busy_timeout: 5_000

# Adapter implementations (overridden to mocks/fakes in test).
config :app,
  text_model: App.Adapters.TextModel.Gemini,
  tts: App.Adapters.Tts.Cartesia,
  stt: App.Adapters.Stt.Cartesia,
  brain_stream: App.Conversations.BrainStream

# The reminder scheduler ticks against the DB; disabled in test (tests call tick/0 directly).
config :app, start_reminder_scheduler: true

# Pool warming makes outbound HTTP calls at boot — only wanted in prod (the deploy host's cold
# connect is the slow one). Off by default so dev/test never hit the network on startup.
config :app, start_pool_warmer: false

# Configure the endpoint
config :app, AppWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AppWeb.ErrorHTML, json: AppWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: App.PubSub,
  live_view: [signing_salt: "x/NCPKvN"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  app: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  app: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Google OAuth: the redirect URI must match exactly what's registered in the Cloud Console.
# Overridable at runtime via GOOGLE_OAUTH_REDIRECT_URI (see runtime.exs).
config :app, :google_redirect_uri, "http://localhost:8787/auth/google/callback"

# Allowlisted users (ordered — first entry is the primary who owns pre-existing connections).
# Set your real users via the ALLOWED_USERS env var (JSON) — see config/runtime.exs + .env.example.
# This is a harmless placeholder so a fresh checkout boots; don't put real emails here.
config :app, :allowed_users, [
  %{email: "you@example.com", name: "You", aliases: []}
]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
