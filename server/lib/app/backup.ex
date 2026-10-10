defmodule App.Backup do
  @moduledoc """
  Nightly SQLite snapshots. Once a day (03:30 instance-local) the live database is copied with
  `VACUUM INTO` to `<db dir>/backups/app-YYYY-MM-DD.db`, and all but the newest `keep`
  snapshots are deleted.

  `VACUUM INTO` writes a consistent, compacted copy while the app keeps running — no lock on
  writers beyond a normal read transaction, and none of the torn-copy risk of `cp` against a
  WAL-mode file. Each snapshot is a complete, directly openable database.

  What this protects against, honestly: a bad migration, a corrupted file, a fat-fingered
  delete — anything that damages the database while the volume survives. It does NOT protect
  against losing the volume itself (the snapshots live on it); getting a copy OFF the box is
  still a separate job. On boot it also takes today's snapshot if the 03:30 run was missed
  (the box was down or redeploying), so a daily redeploy can't silently skip every night.

  Prod-only by default (`:start_backup`); `snapshot/1` is public for tests and manual runs.
  """
  use GenServer
  require Logger

  @keep 14
  @at ~T[03:30:00]
  @boot_delay_ms 5 * 60 * 1000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    state = %{dir: Keyword.get(opts, :dir, default_dir()), keep: Keyword.get(opts, :keep, @keep)}
    if missed_today?(state.dir), do: Process.send_after(self(), :snapshot, @boot_delay_ms)
    schedule_next()
    {:ok, state}
  end

  @impl true
  def handle_info(:snapshot, state) do
    snapshot(dir: state.dir, keep: state.keep)
    {:noreply, state}
  end

  def handle_info(:nightly, state) do
    snapshot(dir: state.dir, keep: state.keep)
    schedule_next()
    {:noreply, state}
  end

  @doc """
  Write today's snapshot now (replacing an earlier one from today) and prune old ones.
  Options: `:dir` (default: `backups/` beside the database), `:keep` (default #{@keep}).
  """
  @spec snapshot(keyword()) :: {:ok, Path.t()} | {:error, term()}
  def snapshot(opts \\ []) do
    dir = Keyword.get(opts, :dir, default_dir())
    keep = Keyword.get(opts, :keep, @keep)
    path = Path.join(dir, "app-#{Date.to_iso8601(local_today())}.db")

    # Into a temp file, then renamed over today's: a failed or interrupted VACUUM never costs the
    # snapshot already there, and never leaves a half-written app-<date>.db that list/latest
    # would report as good.
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(dir),
         # VACUUM INTO refuses an existing target.
         _ <- File.rm(tmp),
         {:ok, _} <- Ecto.Adapters.SQL.query(App.Repo, "VACUUM INTO ?", [tmp]),
         :ok <- File.rename(tmp, path) do
      prune(dir, keep)
      Logger.info("[backup] snapshot written: #{path} (#{File.stat!(path).size} bytes)")
      {:ok, path}
    else
      {:error, reason} = err ->
        Logger.error("[backup] snapshot FAILED: #{inspect(reason)}")
        err
    end
  rescue
    e ->
      Logger.error("[backup] snapshot crashed: #{Exception.message(e)}")
      {:error, e}
  end

  @doc "Snapshot files in `dir`, newest first."
  @spec list(Path.t()) :: [Path.t()]
  def list(dir \\ default_dir()) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&Regex.match?(~r/^app-\d{4}-\d{2}-\d{2}\.db$/, &1))
        |> Enum.sort(:desc)
        |> Enum.map(&Path.join(dir, &1))

      {:error, _} ->
        []
    end
  end

  @doc "The newest snapshot as `%{date: Date.t(), bytes: integer}`, or nil when there is none."
  @spec latest(Path.t()) :: %{date: Date.t(), bytes: non_neg_integer()} | nil
  def latest(dir \\ default_dir()) do
    with [path | _] <- list(dir),
         "app-" <> rest <- Path.basename(path),
         {:ok, date} <- Date.from_iso8601(String.trim_trailing(rest, ".db")),
         {:ok, %{size: bytes}} <- File.stat(path) do
      %{date: date, bytes: bytes}
    else
      _ -> nil
    end
  end

  defp prune(dir, keep) do
    dir |> list() |> Enum.drop(keep) |> Enum.each(&File.rm/1)
  end

  defp missed_today?(dir) do
    now = local_now()

    Time.compare(DateTime.to_time(now), @at) != :lt and
      not File.exists?(Path.join(dir, "app-#{Date.to_iso8601(DateTime.to_date(now))}.db"))
  end

  defp schedule_next do
    now = local_now()
    today = DateTime.to_date(now)
    target = at_local(today)

    target =
      if DateTime.compare(target, now) == :gt, do: target, else: at_local(Date.add(today, 1))

    Process.send_after(self(), :nightly, max(DateTime.diff(target, now, :millisecond), 1_000))
  end

  # 03:30 never falls in a US DST gap/overlap, but resolve both anyway rather than crash.
  defp at_local(date) do
    case DateTime.new(date, @at, App.Config.timezone()) do
      {:ok, dt} -> dt
      {:ambiguous, first, _second} -> first
      {:gap, _before, after_gap} -> after_gap
    end
  end

  defp local_now, do: DateTime.now!(App.Config.timezone())
  defp local_today, do: DateTime.to_date(local_now())

  @doc false
  def default_dir do
    App.Repo.config() |> Keyword.fetch!(:database) |> Path.dirname() |> Path.join("backups")
  end
end
