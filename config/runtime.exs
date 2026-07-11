import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/app start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :app, AppWeb.Endpoint, server: true
end

config :app, AppWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/app/app.db
      """

  config :app, App.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

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

  config :app, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :app, AppWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # IPv4 on all interfaces. The deploy host has no working IPv6 egress (outbound IPv6
      # connects are unreachable), so we disable IPv6 in the container (see docker-compose.yml
      # sysctls) — which means the listener must bind IPv4, not the default IPv6 `:::`.
      ip: {0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :app, AppWeb.Endpoint,
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
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :app, AppWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end

if redirect = System.get_env("GOOGLE_OAUTH_REDIRECT_URI") do
  config :app, :google_redirect_uri, redirect
end

# One IANA timezone for the whole instance (grounds the brain's relative-time resolution and
# local-time display). Unset → the config/config.exs default (America/Chicago). App.Config
# validates it, so a bad value falls back rather than crashing.
if tz = System.get_env("TIMEZONE") do
  config :app, :timezone, tz
end

# Semantic memory (Unified Search M1): Qdrant + Voyage credentials, unset in dev (both adapters
# have fakes wired in test; a missing prod value surfaces as an adapter error, not a boot crash).
if url = System.get_env("QDRANT_URL") do
  config :app, :qdrant_url, url
end

if key = System.get_env("QDRANT_API_KEY") do
  config :app, :qdrant_api_key, key
end

if vk = System.get_env("VOYAGE_API_KEY") do
  config :app, :voyage_api_key, vk
end

# Allowlisted users come from the environment (JSON) so no personal emails live in the repo.
# Format (ordered — the first entry is the primary who owns pre-existing connections):
#   ALLOWED_USERS='[{"email":"you@example.com","name":"You","aliases":["alt@example.com"]}]'
# `aliases` is optional. When unset, the placeholder in config/config.exs applies. See .env.example.
if allowed = System.get_env("ALLOWED_USERS") do
  users =
    allowed
    |> Jason.decode!()
    |> Enum.map(fn u -> %{email: u["email"], name: u["name"], aliases: u["aliases"] || []} end)

  config :app, :allowed_users, users
end

# Trusted-wall user switching (kiosk): OFF unless explicitly enabled. Enable only on the household
# wall deployment — see the security note in specs/2026-07-05-kiosk-identity-design.md. When ON it is
# INSTANCE-GLOBAL (any authed allowlisted client at /?kiosk=1 can switch to any allowlisted user),
# and switching is bounded to the allowlist. Accepts "true"/"1"; anything else (or unset) = OFF.
if System.get_env("KIOSK_USER_SWITCH") in ~w(true 1) do
  config :app, :kiosk_user_switch, true
end

# Vision ("Henry, look at this"): ON by default. Set VISION=false or VISION=0 to disable the
# webcam capture path entirely (the server never asks the browser for a frame). Anything else
# (or unset) leaves it on — it's still gated by the explicit look-phrase + camera permission.
if System.get_env("VISION") in ~w(false 0) do
  config :app, :vision, false
end

# Home Assistant (smart home): instance-wide shared hub — one public URL (Nabu Casa / tunnel) +
# one long-lived access token for the whole household, NOT per-user. Both must be set (and
# HOME_ASSISTANT not "false"/"0") or the config stays absent and the tool never registers —
# Henry simply has no smart-home surface. See specs/2026-07-11-home-assistant-design.md.
ha_url = System.get_env("HOME_ASSISTANT_URL", "")
ha_token = System.get_env("HOME_ASSISTANT_TOKEN", "")

if ha_url != "" and ha_token != "" and System.get_env("HOME_ASSISTANT") not in ~w(false 0) do
  config :app, :home_assistant, %{url: String.trim_trailing(ha_url, "/"), token: ha_token}
end
