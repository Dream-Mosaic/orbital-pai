defmodule App.Tools do
  @moduledoc """
  Tool registry: turns the enabled tool modules into Gemini function declarations and
  dispatches an incoming `functionCall` to the module that declares it, under a per-call
  timeout so a slow or crashing tool can never hang (or kill) a turn.
  """
  require Logger

  alias App.Conversations.Scope

  @default_timeout_ms 8_000

  @doc "Enabled tool modules for this config."
  def enabled(%{tools: tools}), do: tools

  @doc """
  Every enabled tool's own prompt fragment (`c:App.Tools.Tool.prompt/0`), joined into one
  block for the brain's system prompt. "" when no enabled tool contributes one.
  """
  def prompt_block(config) do
    config
    |> enabled()
    |> Enum.filter(fn mod ->
      Code.ensure_loaded?(mod) and function_exported?(mod, :prompt, 0)
    end)
    |> Enum.map(& &1.prompt())
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> ""
      parts -> " " <> Enum.join(parts, " ")
    end
  end

  # run_routine only RETURNS the steps (their own write tools are what get recorded);
  # check_household_messages is a read despite check_off being a write — hence no check_ prefix.
  @read_only ~w(home_status use_toolkit recall_memory check_household_messages run_routine
                code_board claude_jobs)
  @read_prefixes ~w(get_ list_ read_ search_)

  @doc """
  Does calling `name` only LOOK at something (weather, calendar, a list, email…)? Used where a
  repeat is harmless but a write would double (an interrupted request's carried-forward note).
  Read tools follow the get_/list_/read_/search_ naming (plus a few named ones); anything else counts as a write —
  the safe side, since a missed write repeats an action and a missed read only re-reads.
  """
  def read_only?(name) when is_binary(name),
    do: name in @read_only or String.starts_with?(name, @read_prefixes)

  def read_only?(_), do: false

  @doc "The `tools` block for the Gemini request body (flatten every module's declarations)."
  def declarations(config) do
    [%{functionDeclarations: Enum.flat_map(enabled(config), & &1.declarations())}]
  end

  # What a shared household device never offers or runs (spec 2026-10-23-wall-tablet-design,
  # phase 4): an inbox read aloud on the kitchen wall is the wrong default.
  @household_off [App.Tools.Gmail]
  @household_refusal "Email isn't available on the shared household device."

  @doc """
  The turn's config narrowed to a scope (`App.Conversations.Scope`): the household withholds
  the `@household_off` tools, so their declarations never reach the brain. Applied AFTER the
  system instruction is built, which therefore stays the same in both scopes (prefix cache).
  """
  def for_scope(config, :household), do: %{config | tools: config.tools -- @household_off}
  def for_scope(config, _scope), do: config

  @doc """
  Dispatch a function call by name. `ctx` is `%{session_id, config}`. Unknown name →
  `{:error, :unknown_tool}`. A timeout/crash becomes `{:error, :timeout}` /
  `{:error, {:tool_crash, reason}}` — fed back to the model as a tool error, never raised.
  While the session is on a shared household device (`App.Conversations.Scope`), a withheld
  tool (`for_scope/2`) is refused with a reason the brain can say.
  """
  # 3-arity: the brain's normal call path — resolve the per-tool cap (a slow tool like Gmail search
  # can override the default). 4-arity: an explicit cap (tests / special callers).
  def execute(name, args, ctx), do: do_execute(name, args, ctx, nil)
  def execute(name, args, ctx, timeout), do: do_execute(name, args, ctx, timeout)

  defp do_execute(name, args, ctx, timeout) do
    if Scope.current(Map.get(ctx, :session_id)) == :household and household_off?(name) do
      # Dispatch is permissive (a known tool runs even when it wasn't declared), so withholding
      # the declarations isn't enough: a call the brain guesses anyway stops here, before the
      # cache could hand it a result fetched on a personal device.
      Logger.info("[scope] #{name} refused on the shared household device")
      {:error, @household_refusal}
    else
      case find_module(name, ctx.config) do
        nil -> {:error, :unknown_tool}
        mod -> dispatch(mod, name, args, ctx, timeout || tool_timeout(mod, name))
      end
    end
  end

  defp household_off?(name),
    do: Enum.any?(@household_off, fn mod -> Enum.any?(mod.declarations(), &(&1.name == name)) end)

  defp tool_timeout(mod, name) do
    if function_exported?(mod, :timeout, 1), do: mod.timeout(name), else: @default_timeout_ms
  end

  defp dispatch(mod, name, args, ctx, timeout) do
    if cache_enabled?(ctx.config) do
      cached_dispatch(mod, name, args, ctx, timeout)
    else
      run_with_timeout(mod, name, args, ctx, timeout)
    end
  end

  defp cached_dispatch(mod, name, args, ctx, timeout) do
    ttl = tool_cache_ttl(mod, name)
    key = {ctx.session_id, name, tool_cache_key(mod, name, args)}

    case ttl && App.Tools.Cache.get(key) do
      {:ok, _} = hit ->
        Logger.info("[tool-cache] hit #{name} #{App.LogText.said(args)}")
        hit

      _miss ->
        if ttl, do: Logger.debug("[tool-cache] miss #{name} #{inspect(args)}")
        result = run_with_timeout(mod, name, args, ctx, timeout)
        # cache successful reads; a write purges its reads only when it actually succeeded.
        if ttl, do: App.Tools.Cache.put(key, result, ttl)
        if match?({:ok, _}, result), do: purge_invalidated(mod, name)
        result
    end
  end

  defp cache_enabled?(config), do: Map.get(config, :tool_cache, true)

  defp tool_cache_ttl(mod, name) do
    if function_exported?(mod, :cache_ttl, 1), do: mod.cache_ttl(name), else: nil
  end

  defp tool_cache_key(mod, name, args) do
    if function_exported?(mod, :cache_key, 2), do: mod.cache_key(name, args), else: args
  end

  defp purge_invalidated(mod, name) do
    if function_exported?(mod, :cache_invalidates, 1) do
      case mod.cache_invalidates(name) do
        [] ->
          :ok

        names ->
          Enum.each(names, &App.Tools.Cache.purge/1)
          Logger.info("[tool-cache] #{name} purged #{inspect(names)}")
      end
    end

    :ok
  end

  @doc "Canned bridge phrases for a tool by function name ([] if the tool declares none / is unknown)."
  def bridge(name, config) do
    case find_module(name, config) do
      nil -> []
      mod -> if function_exported?(mod, :bridge, 1), do: mod.bridge(name), else: []
    end
  end

  defp find_module(name, config) do
    # Permissive: a toolkit's tools dispatch whether or not the kit is open (the brain may call one
    # before its declarations are advertised); `declarations/1` stays `config.tools` only.
    Enum.find(enabled(config) ++ App.Toolkits.all_tools(config), fn m ->
      Enum.any?(m.declarations(), &(&1.name == name))
    end)
  end

  defp run_with_timeout(mod, name, args, ctx, timeout) do
    started = System.monotonic_time(:millisecond)

    task =
      Task.Supervisor.async_nolink(App.Conversations.TaskSup, fn ->
        mod.execute(name, args, ctx)
      end)

    result =
      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, {:ok, _} = ok} -> ok
        {:ok, {:error, _} = err} -> err
        {:ok, other} -> {:error, {:bad_return, other}}
        {:exit, reason} -> {:error, {:tool_crash, reason}}
        nil -> {:error, :timeout}
      end

    # Timing + outcome of every tool call — proves how long cold tools take vs. their `timeout`,
    # so we can see a successful-but-too-slow fetch get abandoned (the empty-brain root cause).
    elapsed = System.monotonic_time(:millisecond) - started
    Logger.info("[tool] #{name} #{outcome_tag(result)} in #{elapsed}ms (cap #{timeout}ms)")
    result
  end

  defp outcome_tag({:ok, _}), do: "ok"
  defp outcome_tag({:error, :timeout}), do: "TIMEOUT"
  defp outcome_tag({:error, reason}), do: "error #{inspect(reason)}"
end
