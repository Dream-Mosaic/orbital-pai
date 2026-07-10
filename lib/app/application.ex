defmodule App.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Henry v#{App.version()} starting")

    children = [
      AppWeb.Telemetry,
      App.Repo,
      {Ecto.Migrator, repos: Application.fetch_env!(:app, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:app, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: App.PubSub},
      App.Tools.Cache,
      # HTTP pool for Gemini + Cartesia REST (sized for reflex+brain+tts+memory concurrency).
      # Connect timeout covers TCP+TLS AND a possible IPv6→IPv4 fallback (some hosts, e.g. the
      # Coolify box, have no IPv6 egress and the BEAM tries the AAAA first). 2s was too tight there
      # and silently failed every outbound call; 10s leaves room to fall back to IPv4 and succeed.
      # (The image also prefers IPv4 in resolution via /etc/gai.conf — see Dockerfile.)
      {Finch,
       name: App.Finch,
       pools: %{default: [size: 25, conn_opts: [transport_opts: [timeout: 10_000]]]}},
      # Per-session conversation processes: Registry (id -> Conversation),
      # a Task.Supervisor for reflex/brain/memory tasks, and a DynamicSupervisor
      # that owns one Session.Supervisor per live session.
      {Registry, keys: :unique, name: App.Conversations.Registry},
      {Task.Supervisor, name: App.Conversations.TaskSup},
      {DynamicSupervisor, name: App.Conversations.Sup, strategy: :one_for_one},
      # Start to serve requests, typically the last entry
      AppWeb.Endpoint
    ]

    children =
      children ++
        reminder_scheduler() ++
        briefing_scheduler() ++
        memory_consolidator() ++ memory_embedder() ++ source_ingester() ++ pool_warmer()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: App.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp reminder_scheduler do
    if Application.get_env(:app, :start_reminder_scheduler, true),
      do: [App.Reminders.Scheduler],
      else: []
  end

  defp briefing_scheduler do
    if Application.get_env(:app, :start_briefing_scheduler, true),
      do: [App.Agenda.Briefing],
      else: []
  end

  defp memory_consolidator do
    if Application.get_env(:app, :start_memory_consolidator, true),
      do: [App.Memory.Consolidator],
      else: []
  end

  defp memory_embedder do
    if Application.get_env(:app, :start_memory_embedder, true),
      do: [App.Memory.Embedder],
      else: []
  end

  defp source_ingester do
    if Application.get_env(:app, :start_source_ingester, true),
      do: [App.Sources.Ingester],
      else: []
  end

  # Warm the outbound HTTP pools at boot (prod only). Runs after Finch + TaskSup, which it uses.
  defp pool_warmer do
    if Application.get_env(:app, :start_pool_warmer, false),
      do: [App.Http.Warmer],
      else: []
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AppWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
