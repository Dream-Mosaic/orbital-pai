import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :app, App.Repo,
  database: Path.expand("../app_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :app, AppWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "J6VaTyGjodFi5ajAq9TDngRheUcwhW8zk7dSV1YoqsD1kTJhroBTE5JYLb7EIQ4c",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Don't run the background reminder scheduler in tests (no sandbox owner on its tick process).
config :app, start_reminder_scheduler: false
config :app, start_briefing_scheduler: false
config :app, start_memory_consolidator: false

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
