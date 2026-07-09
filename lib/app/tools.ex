defmodule App.Tools do
  @moduledoc """
  Tool registry: turns the enabled tool modules into Gemini function declarations and
  dispatches an incoming `functionCall` to the module that declares it, under a per-call
  timeout so a slow or crashing tool can never hang (or kill) a turn.
  """
  require Logger

  @default_timeout_ms 8_000

  @doc "Enabled tool modules for this config."
  def enabled(%{tools: tools}), do: tools

  @doc "The `tools` block for the Gemini request body (flatten every module's declarations)."
  def declarations(config) do
    [%{functionDeclarations: Enum.flat_map(enabled(config), & &1.declarations())}]
  end

  @doc """
  Dispatch a function call by name. `ctx` is `%{session_id, config}`. Unknown name →
  `{:error, :unknown_tool}`. A timeout/crash becomes `{:error, :timeout}` /
  `{:error, {:tool_crash, reason}}` — fed back to the model as a tool error, never raised.
  """
  # 3-arity: the brain's normal call path — resolve the per-tool cap (a slow tool like Gmail search
  # can override the default). 4-arity: an explicit cap (tests / special callers).
  def execute(name, args, ctx), do: do_execute(name, args, ctx, nil)
  def execute(name, args, ctx, timeout), do: do_execute(name, args, ctx, timeout)

  defp do_execute(name, args, ctx, timeout) do
    case find_module(name, ctx.config) do
      nil -> {:error, :unknown_tool}
      mod -> dispatch(mod, name, args, ctx, timeout || tool_timeout(mod, name))
    end
  end

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
        Logger.info("[tool-cache] hit #{name} #{inspect(args)}")
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
    Enum.find(enabled(config), fn m -> Enum.any?(m.declarations(), &(&1.name == name)) end)
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
