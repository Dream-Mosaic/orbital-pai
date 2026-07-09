defmodule App.ToolsTest do
  # async: false — tool execution runs under the shared App.Conversations.TaskSup.
  use ExUnit.Case, async: false

  alias App.Config
  alias App.Test.Fakes.{FakeTool, SlowTool, CrashTool, BadReturnTool, CacheTool}

  defp ctx(tools), do: %{session_id: "default", config: %Config{tools: tools}}

  setup do
    App.Tools.Cache.clear()
    :ok
  end

  defp cache_ctx, do: %{session_id: "default", config: %Config{tools: [CacheTool]}}

  test "declarations/1 flattens every enabled module's function declarations" do
    [%{functionDeclarations: decls}] = App.Tools.declarations(%Config{tools: [FakeTool]})
    assert [%{name: "echo"}] = decls
  end

  test "execute/3 dispatches a call by name to the owning module" do
    assert {:ok, %{echoed: "hi"}} = App.Tools.execute("echo", %{"msg" => "hi"}, ctx([FakeTool]))
  end

  test "execute/3 returns :unknown_tool for a name no module declares" do
    assert {:error, :unknown_tool} = App.Tools.execute("nope", %{}, ctx([FakeTool]))
  end

  test "execute/4 enforces a timeout so a stuck tool can't hang the turn" do
    assert {:error, :timeout} = App.Tools.execute("slow", %{}, ctx([SlowTool]), 50)
  end

  test "execute/3 honors a tool's own timeout/1 cap (not the 8s default)" do
    started = System.monotonic_time(:millisecond)
    assert {:error, :timeout} = App.Tools.execute("slow", %{}, ctx([SlowTool]))
    # SlowTool.timeout("slow") is 40ms — proves the per-tool cap was used, not the 8s default.
    assert System.monotonic_time(:millisecond) - started < 1_000
  end

  test "execute maps a raising tool to a tool_crash error (never propagates)" do
    assert {:error, {:tool_crash, _}} = App.Tools.execute("crash", %{}, ctx([CrashTool]))
  end

  test "execute maps a non-{:ok|:error} return to a bad_return error" do
    assert {:error, {:bad_return, :not_a_tuple}} =
             App.Tools.execute("bad", %{}, ctx([BadReturnTool]))
  end

  test "a cacheable read returns the cached value on the second call" do
    {:ok, %{val: v1}} = App.Tools.execute("cached_read", %{}, cache_ctx())
    {:ok, %{val: v2}} = App.Tools.execute("cached_read", %{}, cache_ctx())
    assert v1 == v2
  end

  test "a non-cacheable tool re-runs every call" do
    {:ok, %{val: v1}} = App.Tools.execute("uncached_read", %{}, cache_ctx())
    {:ok, %{val: v2}} = App.Tools.execute("uncached_read", %{}, cache_ctx())
    assert v1 != v2
  end

  test "different args are cached separately" do
    {:ok, %{val: a}} = App.Tools.execute("cached_read", %{"x" => 1}, cache_ctx())
    {:ok, %{val: b}} = App.Tools.execute("cached_read", %{"x" => 2}, cache_ctx())
    {:ok, %{val: a2}} = App.Tools.execute("cached_read", %{"x" => 1}, cache_ctx())
    assert a != b
    assert a == a2
  end

  test "errors are not cached" do
    assert {:error, :boom} = App.Tools.execute("err_read", %{}, cache_ctx())
    assert App.Tools.Cache.get({"default", "err_read", %{}}) == nil
  end

  test "a write purges its declared read cache" do
    {:ok, %{val: v1}} = App.Tools.execute("cached_read", %{}, cache_ctx())
    {:ok, _} = App.Tools.execute("cache_write", %{}, cache_ctx())
    {:ok, %{val: v2}} = App.Tools.execute("cached_read", %{}, cache_ctx())
    assert v1 != v2
  end

  test "cache_key normalizes the key so calls differing only by a volatile arg collide" do
    {:ok, %{val: v1}} = App.Tools.execute("cached_read", %{"volatile" => 1}, cache_ctx())
    {:ok, %{val: v2}} = App.Tools.execute("cached_read", %{"volatile" => 2}, cache_ctx())
    assert v1 == v2
  end

  test "a FAILED write does not purge the read cache" do
    {:ok, %{val: v1}} = App.Tools.execute("cached_read", %{}, cache_ctx())
    {:error, :nope} = App.Tools.execute("err_write", %{}, cache_ctx())
    {:ok, %{val: v2}} = App.Tools.execute("cached_read", %{}, cache_ctx())
    assert v1 == v2
  end

  test "caching is skipped when tool_cache is false" do
    ctx = %{session_id: "default", config: %Config{tools: [CacheTool], tool_cache: false}}
    {:ok, %{val: v1}} = App.Tools.execute("cached_read", %{}, ctx)
    {:ok, %{val: v2}} = App.Tools.execute("cached_read", %{}, ctx)
    assert v1 != v2
  end

  test "bridge/2 returns a tool's declared phrases by function name; [] otherwise" do
    cfg = %Config{tools: [App.Tools.Calendar, App.Tools.Weather, App.Tools.Reminders]}

    # non-empty lists of non-blank strings (catches a regression returning [""] / [nil])
    for name <- ["get_calendar_events", "create_event", "get_weather"] do
      phrases = App.Tools.bridge(name, cfg)
      assert phrases != []
      assert Enum.all?(phrases, &(is_binary(&1) and &1 != ""))
    end

    assert App.Tools.bridge("list_reminders", cfg) == []
    assert App.Tools.bridge("nope", cfg) == []
  end
end
