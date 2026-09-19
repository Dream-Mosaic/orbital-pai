defmodule App do
  @moduledoc """
  App keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  @doc """
  The deployed server version, e.g. `0.5.0`. Bump it with `./bump.sh server …`.

  Read from `priv/VERSION` at RUNTIME, not from mix.exs. The Dockerfile's dependency layers
  are keyed on mix.exs (`COPY mix.exs mix.lock` → `deps.get` → `deps.compile`, which builds
  Ortex's Rust and EXLA from source), so a version living there made every bump a cold
  dependency build — and the bump rule stopped being followed, which froze the UI on 0.4.19
  for two months (issue #1). `priv/` is copied AFTER `deps.compile`, so a bump now only
  rebuilds the app's own layers.

  Cached in `:persistent_term` after the first read; falls back to the mix.exs vsn if the
  file is missing or blank, so a broken stamp degrades to an old number, never a crash.
  """
  @spec version() :: String.t()
  def version do
    case :persistent_term.get({__MODULE__, :version}, nil) do
      nil ->
        v = read_version(Application.app_dir(:app, "priv/VERSION"))
        :persistent_term.put({__MODULE__, :version}, v)
        v

      v ->
        v
    end
  end

  @doc false
  @spec read_version(Path.t()) :: String.t()
  def read_version(path) do
    with {:ok, raw} <- File.read(path),
         v when v != "" <- String.trim(raw) do
      v
    else
      _ -> :app |> Application.spec(:vsn) |> to_string()
    end
  end
end
