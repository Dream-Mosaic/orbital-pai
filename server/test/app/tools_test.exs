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

  defmodule PromptTool do
    @behaviour App.Tools.Tool
    def declarations, do: [%{name: "p", description: "p", parameters: %{type: "object"}}]
    def execute(_n, _a, _c), do: {:ok, %{}}
    def prompt, do: "Use p for p-things."
  end

  test "prompt_block/1 joins the enabled tools' own prompt fragments; none -> empty" do
    assert App.Tools.prompt_block(%Config{tools: [FakeTool, PromptTool]}) ==
             " Use p for p-things."

    assert App.Tools.prompt_block(%Config{tools: [FakeTool]}) == ""
  end

  test "read_only?/1 tells lookups from tools that change something" do
    for name <-
          ~w(get_weather get_calendar_events list_timers read_list search_email read_email
                   recall_memory home_status check_household_messages run_routine get_recipe),
        do: assert(App.Tools.read_only?(name), name)

    for name <- ~w(set_timer add_to_list check_off create_reminder send_email
                   send_household_message log_tracker_entry home_control play_music save_recipe),
        do: refute(App.Tools.read_only?(name), name)
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

  # Phase 4 (spec 2026-10-23-wall-tablet-design): on a shared household device the brain is not
  # offered Gmail, and because dispatch is permissive (a known tool runs even when it wasn't
  # declared) a call it guesses anyway is refused here, too.
  describe "on a shared household device" do
    @refusal "Email isn't available on the shared household device."

    setup do
      %{sid: "household-#{System.unique_integer([:positive])}"}
    end

    # What the session's Conversation publishes while bound to a shared device.
    defp household!(sid),
      do: {:ok, _} = Registry.register(App.Conversations.Registry, sid, :household)

    defp gmail_ctx(sid),
      do: %{session_id: sid, user_id: nil, config: %Config{tools: [App.Tools.Gmail]}}

    test "execute/3 refuses every Gmail tool with a reason the brain can say", %{sid: sid} do
      household!(sid)

      for name <- ~w(search_email read_email send_email),
          do: assert({:error, @refusal} == App.Tools.execute(name, %{}, gmail_ctx(sid)), name)
    end

    test "the refusal comes before the tool cache", %{sid: sid} do
      # a personal-scope search caches its result under this session...
      assert {:ok, %{messages: []}} = App.Tools.execute("search_email", %{}, gmail_ctx(sid))
      # ...which must not be served once the session is on the shared device
      household!(sid)
      assert {:error, @refusal} = App.Tools.execute("search_email", %{}, gmail_ctx(sid))
    end

    test "every other tool still runs", %{sid: sid} do
      household!(sid)
      ctx = %{session_id: sid, config: %Config{tools: [FakeTool]}}
      assert {:ok, %{echoed: "hi"}} = App.Tools.execute("echo", %{"msg" => "hi"}, ctx)
    end

    test "for_scope/2 withholds Gmail from the household and leaves a personal config alone" do
      cfg = %Config{tools: [FakeTool, App.Tools.Gmail]}
      assert App.Tools.for_scope(cfg, :personal) == cfg
      assert App.Tools.for_scope(cfg, :household).tools == [FakeTool]
    end
  end
end
