defmodule App.Adapters.TextModel.GeminiTest do
  use ExUnit.Case, async: true
  alias App.Adapters.TextModel.Gemini
  alias App.Config

  defp call(name, extra \\ %{}),
    do: Map.merge(%{name: name, args: %{}, sig: nil, id: nil}, extra)

  test "maybe_put_tools/3 with tools? = false strips the tools block (forced final answer round)" do
    body = %{contents: []}
    cfg = %Config{web_search: false}
    # tools-on (default 2-arity behaviour preserved) adds a tools block...
    assert Map.has_key?(Gemini.maybe_put_tools(body, cfg), :tools)
    # ...tools-off explicitly omits it, so the model must answer instead of calling a tool.
    refute Map.has_key?(Gemini.maybe_put_tools(body, cfg, false), :tools)
  end

  test "at the tool-hop cap, run_rounds forces ONE tools-off final round, then done (never silent)" do
    parent = self()

    # A round runner that always asks for another tool — without a cap this loops forever.
    # It records the tools? flag of every round so we can prove the final one disabled tools.
    round_fun = fn _contents, _system, _cfg, _thinking, _target, tools? ->
      send(parent, {:round, tools?})
      {:ok, [call("noop")]}
    end

    cfg = %Config{}
    tool_ctx = %{session_id: nil, user_id: nil, config: cfg}
    Gemini.run_rounds([], "sys", cfg, "low", tool_ctx, self(), 0, round_fun)

    # hops 0..3 run with tools on; the cap (hops >= 3) then forces exactly one tools-off round.
    assert_received {:round, true}
    assert_received {:round, true}
    assert_received {:round, true}
    assert_received {:round, true}
    assert_received {:round, false}
    refute_received {:round, _}
    # and the turn still ends cleanly rather than going silent
    assert_received {:gemini_done}
    refute_received {:gemini_error, _}
  end

  test "a round's tool calls execute concurrently" do
    defmodule TwoSleepers do
      @behaviour App.Tools.Tool
      def declarations do
        for n <- ["sleep_a", "sleep_b"] do
          %{name: n, description: n, parameters: %{type: "object", properties: %{}, required: []}}
        end
      end

      def execute(_n, _a, _c) do
        Process.sleep(150)
        {:ok, %{ok: true}}
      end
    end

    cfg = %App.Config{tools: [TwoSleepers], web_search: false, tool_cache: false}
    tool_ctx = %{session_id: nil, user_id: nil, config: cfg}
    me = self()

    round_fun = fn _contents, _system, _cfg, _thinking, _target, tools? ->
      if tools? and not Process.get(:sent_calls, false) do
        Process.put(:sent_calls, true)
        {:ok, [call("sleep_a"), call("sleep_b")]}
      else
        {:ok, []}
      end
    end

    {elapsed_us, _} =
      :timer.tc(fn ->
        App.Adapters.TextModel.Gemini.run_rounds(
          [],
          "sys",
          cfg,
          "low",
          tool_ctx,
          me,
          0,
          round_fun
        )
      end)

    assert_receive {:gemini_done}
    # sequential would be >= 300ms; concurrent stays well under
    assert elapsed_us < 280_000
  end

  test "each tool call in a round is announced to the owner before it executes" do
    cfg = %App.Config{tools: [], web_search: false, tool_cache: false}
    tool_ctx = %{session_id: nil, user_id: nil, config: cfg}

    round_fun = fn _contents, _system, _cfg, _thinking, _target, tools? ->
      if tools? and not Process.get(:sent_calls, false) do
        Process.put(:sent_calls, true)
        {:ok, [call("sleep_a"), call("sleep_b")]}
      else
        {:ok, []}
      end
    end

    App.Adapters.TextModel.Gemini.run_rounds(
      [],
      "sys",
      cfg,
      "low",
      tool_ctx,
      self(),
      0,
      round_fun
    )

    # before executing a round, each call is announced to the owner
    assert_receive {:gemini_tool_call, "sleep_a"}
    assert_receive {:gemini_tool_call, "sleep_b"}
    assert_receive {:gemini_done}
  end

  test "each successful tool result is relayed to the owner (for cards); errors are not" do
    defmodule CardSource do
      @behaviour App.Tools.Tool
      def declarations do
        for n <- ["good_tool", "bad_tool"] do
          %{name: n, description: n, parameters: %{type: "object", properties: %{}, required: []}}
        end
      end

      def execute("good_tool", _a, _c), do: {:ok, %{temp: 72}}
      def execute("bad_tool", _a, _c), do: {:error, :nope}
    end

    cfg = %App.Config{tools: [CardSource], web_search: false, tool_cache: false}
    tool_ctx = %{session_id: nil, user_id: nil, config: cfg}

    round_fun = fn _contents, _system, _cfg, _thinking, _target, tools? ->
      if tools? and not Process.get(:sent_calls, false) do
        Process.put(:sent_calls, true)
        {:ok, [call("good_tool", %{args: %{"where" => "home"}}), call("bad_tool")]}
      else
        {:ok, []}
      end
    end

    Gemini.run_rounds([], "sys", cfg, "low", tool_ctx, self(), 0, round_fun)

    assert_receive {:gemini_tool_result, "good_tool", %{"where" => "home"}, %{temp: 72}}
    assert_receive {:gemini_done}
    refute_received {:gemini_tool_result, "bad_tool", _, _}
  end

  test "tools_block includes function tools AND googleSearch when web_search is on" do
    assert [%{functionDeclarations: decls}, %{googleSearch: %{}}] =
             Gemini.tools_block(%Config{web_search: true})

    assert is_list(decls) and decls != []
  end

  test "tools_block omits googleSearch when web_search is off" do
    assert [%{functionDeclarations: _}] = Gemini.tools_block(%Config{web_search: false})
  end

  test "tools_block is just googleSearch when no function tools but web_search is on" do
    assert Gemini.tools_block(%Config{tools: [], web_search: true}) == [%{googleSearch: %{}}]
  end

  test "tools_block is nil when there are no tools and web_search is off" do
    assert Gemini.tools_block(%Config{tools: [], web_search: false}) == nil
  end

  test "maybe_put_tools opts into server-side tools when web_search is on (Gemini 3 requires it)" do
    body = Gemini.maybe_put_tools(%{}, %Config{web_search: true})

    assert [%{functionDeclarations: _}, %{googleSearch: %{}}] = body.tools
    assert body.toolConfig == %{includeServerSideToolInvocations: true}
  end

  test "maybe_put_tools omits toolConfig when web_search is off" do
    body = Gemini.maybe_put_tools(%{}, %Config{web_search: false})

    assert [%{functionDeclarations: _}] = body.tools
    refute Map.has_key?(body, :toolConfig)
  end

  test "build_contents threads recent turns as alternating user/model history, current line last" do
    ctx = %{
      recent: [
        %{user_text: "my name is Bobby", brain_text: "Nice to meet you, Bobby."},
        %{user_text: "i like tea", brain_text: "Tea's a great choice."}
      ]
    }

    assert Gemini.build_contents(ctx, "what's my name?") == [
             %{role: "user", parts: [%{text: "my name is Bobby"}]},
             %{role: "model", parts: [%{text: "Nice to meet you, Bobby."}]},
             %{role: "user", parts: [%{text: "i like tea"}]},
             %{role: "model", parts: [%{text: "Tea's a great choice."}]},
             %{role: "user", parts: [%{text: "what's my name?"}]}
           ]
  end

  test "build_contents skips turns missing either side (keeps clean alternation)" do
    ctx = %{recent: [%{user_text: "hi", brain_text: nil}, %{user_text: "", brain_text: "x"}]}

    assert Gemini.build_contents(ctx, "hello") == [
             %{role: "user", parts: [%{text: "hello"}]}
           ]
  end

  test "build_contents with no recent (reflex/memory tiers) is just the current line" do
    assert Gemini.build_contents(%{}, "just this") == [
             %{role: "user", parts: [%{text: "just this"}]}
           ]
  end

  describe "age_marker/2" do
    @now ~U[2026-07-03 12:00:00Z]
    test "buckets" do
      assert Gemini.age_marker(~U[2026-07-03 11:50:00Z], @now) == nil
      assert Gemini.age_marker(~U[2026-07-03 11:22:00Z], @now) == "[38m ago]"
      assert Gemini.age_marker(~U[2026-07-03 07:00:00Z], @now) == "[5h ago]"
      assert Gemini.age_marker(~U[2026-07-01 09:00:00Z], @now) == "[on 2026-07-01]"
      assert Gemini.age_marker(nil, @now) == nil
    end
  end

  test "build_contents prefixes old history turns, not the live transcript" do
    old = %{
      user_text: "plant the tomatoes",
      brain_text: "noted",
      inserted_at: DateTime.add(DateTime.utc_now(), -5 * 3600, :second)
    }

    fresh = %{user_text: "thanks", brain_text: "sure", inserted_at: DateTime.utc_now()}

    [h1, _a1, h2, _a2, live] =
      Gemini.build_contents(%{recent: [old, fresh]}, "what did I say to plant?")

    assert [%{text: t1}] = h1.parts
    assert String.starts_with?(t1, "[5h ago] plant the tomatoes")
    assert [%{text: "thanks"}] = h2.parts
    assert [%{text: "what did I say to plant?"}] = live.parts
  end

  test "build_contents/2 with no history -> a single text part on the final user message" do
    [msg] = Gemini.build_contents(%{}, "what's up")
    assert msg == %{role: "user", parts: [%{text: "what's up"}]}
  end

  test "extract_calls pulls functionCall parts (with the thought_signature) out of a chunk" do
    decoded = %{
      "candidates" => [
        %{
          "content" => %{
            "parts" => [
              %{
                "functionCall" => %{"name" => "get_weather", "args" => %{"location" => "STL"}},
                "thoughtSignature" => "sig-abc"
              }
            ]
          }
        }
      ]
    }

    assert Gemini.extract_calls(decoded) == [
             call("get_weather", %{args: %{"location" => "STL"}, sig: "sig-abc"})
           ]
  end

  test "extract_calls carries the functionCall id (Gemini 3.x sends one per call)" do
    decoded = %{
      "candidates" => [
        %{
          "content" => %{
            "parts" => [
              %{"functionCall" => %{"id" => "c1", "name" => "get_weather", "args" => %{}}},
              %{"functionCall" => %{"id" => "c2", "name" => "list_reminders", "args" => %{}}}
            ]
          }
        }
      ]
    }

    assert Gemini.extract_calls(decoded) == [
             call("get_weather", %{id: "c1"}),
             call("list_reminders", %{id: "c2"})
           ]
  end

  test "extract_calls keeps a nil signature and id when the part has neither" do
    decoded = %{
      "candidates" => [
        %{"content" => %{"parts" => [%{"functionCall" => %{"name" => "f", "args" => %{}}}]}}
      ]
    }

    assert Gemini.extract_calls(decoded) == [call("f")]
  end

  test "extract_calls is [] when there are no function calls" do
    decoded = %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "hi"}]}}]}
    assert Gemini.extract_calls(decoded) == []
  end

  test "model_call_parts echoes the thought_signature back (Gemini 3 requires it)" do
    calls = [call("get_weather", %{args: %{"location" => "STL"}, sig: "sig-abc"})]

    assert Gemini.model_call_parts(calls) == [
             %{
               functionCall: %{name: "get_weather", args: %{"location" => "STL"}},
               thoughtSignature: "sig-abc"
             }
           ]
  end

  test "model_call_parts echoes the functionCall id back as received" do
    assert Gemini.model_call_parts([call("f", %{id: "c1"})]) == [
             %{functionCall: %{id: "c1", name: "f", args: %{}}}
           ]
  end

  test "model_call_parts omits the signature and id keys when there aren't any" do
    assert Gemini.model_call_parts([call("f")]) == [
             %{functionCall: %{name: "f", args: %{}}}
           ]
  end

  test "function_response_parts pairs each response with its call's id and name" do
    calls = [call("get_weather", %{id: "c1"}), call("list_reminders", %{id: "c2"})]
    responses = [%{result: %{temp_f: 70}}, %{error: "timeout"}]

    assert Gemini.function_response_parts(calls, responses) == [
             %{
               functionResponse: %{
                 id: "c1",
                 name: "get_weather",
                 response: %{result: %{temp_f: 70}}
               }
             },
             %{
               functionResponse: %{
                 id: "c2",
                 name: "list_reminders",
                 response: %{error: "timeout"}
               }
             }
           ]
  end

  test "function_response_parts omits the id key when the call had none" do
    assert Gemini.function_response_parts([call("get_weather")], [%{result: %{temp_f: 70}}]) == [
             %{functionResponse: %{name: "get_weather", response: %{result: %{temp_f: 70}}}}
           ]
  end

  test "a tool round's continuation echoes each call id on both the call and its response" do
    cfg = %App.Config{tools: [], web_search: false, tool_cache: false}
    tool_ctx = %{session_id: nil, user_id: nil, config: cfg}
    me = self()

    round_fun = fn contents, _system, _cfg, _thinking, _target, tools? ->
      if tools? and not Process.get(:sent_calls, false) do
        Process.put(:sent_calls, true)
        {:ok, [call("tool_a", %{id: "c1", sig: "s1"}), call("tool_b", %{id: "c2"})]}
      else
        send(me, {:continuation, contents})
        {:ok, []}
      end
    end

    Gemini.run_rounds([], "sys", cfg, "low", tool_ctx, me, 0, round_fun)

    assert_receive {:continuation, [model_turn, response_turn]}

    assert %{role: "model", parts: [%{functionCall: %{id: "c1"}}, %{functionCall: %{id: "c2"}}]} =
             model_turn

    # Unknown tools error — the error response must still be paired with its own call's id.
    assert %{
             role: "user",
             parts: [
               %{functionResponse: %{id: "c1", name: "tool_a", response: %{error: _}}},
               %{functionResponse: %{id: "c2", name: "tool_b", response: %{error: _}}}
             ]
           } = response_turn
  end

  test "bridge_phrase is nil when tool_bridges is off" do
    assert Gemini.bridge_phrase([call("get_weather")], %Config{tool_bridges: false}) == nil
  end

  test "bridge_phrase picks a declared phrase for a phrase-bearing call" do
    cfg = %Config{tools: [App.Tools.Weather], tool_bridges: true}
    phrase = Gemini.bridge_phrase([call("get_weather")], cfg)
    assert phrase in App.Tools.Weather.bridge("get_weather")
  end

  test "bridge_phrase is nil when no call has a phrase" do
    cfg = %Config{tools: [App.Tools.Reminders], tool_bridges: true}
    assert Gemini.bridge_phrase([call("list_reminders")], cfg) == nil
  end

  test "bridge_phrase picks the FIRST phrase-bearing call" do
    cfg = %Config{tools: [App.Tools.Weather, App.Tools.Calendar], tool_bridges: true}

    phrase =
      Gemini.bridge_phrase(
        [call("get_weather"), call("get_calendar_events")],
        cfg
      )

    assert phrase in App.Tools.Weather.bridge("get_weather")
  end

  test "the brain system prompt carries STATIC time guidance but no dynamic timestamp line" do
    prompt = App.Adapters.TextModel.Gemini.brain_prompt("Henry")
    assert prompt =~ "ISO8601 UTC"
    assert prompt =~ "local timezone"
    # the offset-comparison guidance from the grounding fix is static, so it lives here too
    assert prompt =~ "absolute instant"
    # the DYNAMIC time prefix (time_note) must NOT be baked into the static prompt
    refute prompt =~ "(Current time:"
  end

  test "time_note/1 is the dynamic per-turn line, LOCAL-first (preserves the grounding fix)" do
    note = App.Adapters.TextModel.Gemini.time_note(%App.Config{})
    # local time with its offset + the zone name — NOT UTC-only (see the timezone grounding fix)
    assert note =~ "(Current time: "
    assert note =~ "(America/Chicago)"
    assert note =~ "In UTC that is "
    assert String.ends_with?(note, "\n")
  end

  test "quiet_note/1 tells the brain a typed turn is read, not heard; a voice turn gets nothing" do
    note = Gemini.quiet_note(quiet: true)
    assert note =~ "TYPED"
    assert note =~ "won't be spoken"
    assert String.ends_with?(note, "\n")

    assert Gemini.quiet_note([]) == ""
    assert Gemini.quiet_note(quiet: false) == ""
  end

  test "brain prompt teaches the follow-up offer" do
    prompt = Gemini.brain_prompt("Henry")
    assert prompt =~ "follow-up"
    assert prompt =~ "confirm"
  end

  test "brain prompt teaches the lists tool: books vs to-do, shared-by-default, read back who" do
    prompt = Gemini.brain_prompt("Henry")
    assert prompt =~ "add_to_list"
    assert prompt =~ "book"
    assert prompt =~ ~r/shared by default/i
  end

  test "brain prompt teaches the garden book: loose record, seasonal archive, shared like lists" do
    prompt = Gemini.brain_prompt("Henry")
    assert prompt =~ "garden book"
    assert prompt =~ "add_plant"
    assert prompt =~ "note_plant"
    assert prompt =~ "list_garden"
    assert prompt =~ "close_season"
    assert prompt =~ "create_reminder"
    # editing is non-destructive: change details in place, don't remove + re-add (loses notes)
    assert prompt =~ "update_plant"
    assert prompt =~ ~r/never remove and re-add/
  end

  test "brain prompt teaches garden care coaching: offer care + a reminder, confirm, cleanup on retire" do
    prompt = Gemini.brain_prompt("Henry")
    # Henry proactively COACHES on plant care (reverses the old slice-1 "don't invent schedules").
    assert prompt =~ "coach"
    # ...but still offer→confirm→create, never unprompted.
    assert prompt =~ ~r/only create it with create_reminder .* after they say yes/
    assert prompt =~ "never set a plant reminder unprompted"
    # conversational cleanup: offer to cancel a retired plant's care reminders.
    assert prompt =~ ~r/retires a plant.*cancel_reminder/
    # care basics may be jotted onto the plant card.
    assert prompt =~ ~r/note the care basics onto the plant with note_plant/
  end

  test "brain prompt forbids Henry from acknowledging a reminder on his own (delivery != ack)" do
    prompt = Gemini.brain_prompt("Henry")
    # It must teach the ack tool...
    assert prompt =~ "acknowledge_reminder"
    # ...but explicitly that delivering is NOT acking, and he must not self-ack.
    assert prompt =~ "never call acknowledge_reminder on your own"
    assert prompt =~ ~r/not acknowledging it/i
  end

  test "brain prompt treats email (Gmail) as a real capability, not a can't-do" do
    prompt = Gemini.brain_prompt("Henry")
    # Gmail shipped — email must NOT be listed among things Henry can't do yet.
    refute prompt =~ ~r/do yet[^.]*email/
    # and it's named as a capability.
    assert prompt =~ "email"
  end

  test "brain prompt no longer lists smart home as a can't-do" do
    prompt = Gemini.brain_prompt("Henry")
    refute prompt =~ "smart home"
    # the graceful can't-do line itself survives
    assert prompt =~ "genuinely can't do yet"
  end

  test "brain prompt teaches repeating reminders (due_at = first occurrence + recurrence) and cancel_reminder" do
    prompt = Gemini.brain_prompt("Henry")
    assert prompt =~ "recurrence"
    assert prompt =~ "FIRST occurrence"
    assert prompt =~ "cancel_reminder"
    assert prompt =~ ~r/daily\/weekly\/monthly\/yearly/
  end

  test "memory_block names the rest of the household after the speaker" do
    block =
      Gemini.memory_block(%{user_name: "David", household: ["Tanya"], profile: "", summary: ""})

    assert block == "\n\nYou're speaking with David. Also in the household: Tanya."

    assert Gemini.memory_block(%{user_name: "David", household: [], profile: "", summary: ""}) ==
             "\n\nYou're speaking with David."
  end

  test "memory_block leads with identity, with or without notes" do
    with_notes =
      Gemini.memory_block(%{user_name: "David", profile: "- likes drones", summary: ""})

    assert with_notes =~ "You're speaking with David."
    assert with_notes =~ "likes drones"

    bare = Gemini.memory_block(%{user_name: "David", profile: "", summary: ""})
    assert bare =~ "You're speaking with David."

    assert Gemini.memory_block(%{user_name: nil, profile: "", summary: ""}) == ""
  end

  test "a carded tool result tells the brain the user can see it; others are untouched" do
    weather = %{location: "X", current: %{temp_f: 64.2, conditions: "overcast"}}
    noted = Gemini.with_card_note(%{result: weather}, "get_weather", %{}, weather)
    assert noted.display =~ "visual card"
    assert noted.result == weather

    plain = %{result: %{ok: true}}
    assert Gemini.with_card_note(plain, "set_timer", %{}, %{ok: true}) == plain
  end

  test "a cook-mode step on screen is still read aloud: the cook's hands are busy" do
    recipe =
      App.Tools.Recipes.recipe_view(%App.Recipes.Recipe{
        title: "Lasagna",
        household: true,
        ingredients: ["noodles"],
        steps: ["Boil the noodles.", "Bake 25 minutes."]
      })

    step = Map.put(recipe, :current_step, 2)
    noted = Gemini.with_card_note(%{result: step}, "get_recipe", %{"step" => 2}, step)
    assert noted.display =~ "screen"
    assert noted.display =~ "still read the step aloud"
    refute noted.display =~ "Don't recite"

    # the plain recipe lookup keeps the ordinary note
    overview = Gemini.with_card_note(%{result: recipe}, "get_recipe", %{}, recipe)
    assert overview.display =~ "Don't recite"
  end

  test "a routine with an extra dependent lookup still finishes with tools (routine hop refund)" do
    # run → status+calendar → status → act → answer: one hop past the plain cap, absorbed by
    # the refund the first run_routine earns.
    parent = self()

    Process.put(:script, [
      [call("run_routine")],
      [call("home_status"), call("get_calendar_events")],
      [call("home_status")],
      [call("home_control")],
      []
    ])

    round_fun = fn _contents, _system, _cfg, _thinking, _target, tools? ->
      send(parent, {:round, tools?})
      [calls | rest] = Process.get(:script)
      Process.put(:script, rest)
      {:ok, calls}
    end

    cfg = %Config{tools: [], web_search: false, tool_cache: false}
    tool_ctx = %{session_id: nil, user_id: nil, config: cfg}
    Gemini.run_rounds([], "sys", cfg, "low", tool_ctx, self(), 0, round_fun)

    for _ <- 1..5, do: assert_received({:round, true})
    refute_received {:round, false}
    assert_received {:gemini_done}
  end

  test "the routine refund is once per turn — re-calling run_routine can't loop" do
    parent = self()

    round_fun = fn _contents, _system, _cfg, _thinking, _target, tools? ->
      send(parent, {:round, tools?})
      if tools?, do: {:ok, [call("run_routine")]}, else: {:ok, []}
    end

    cfg = %Config{tools: [], web_search: false, tool_cache: false}
    tool_ctx = %{session_id: nil, user_id: nil, config: cfg}
    Gemini.run_rounds([], "sys", cfg, "low", tool_ctx, self(), 0, round_fun)

    # 1 refunded routine round + 3 counted rounds, then the forced tools-off answer
    for _ <- 1..6, do: assert_received({:round, true})
    assert_received {:round, false}
    assert_received {:gemini_done}
  end

  test "a look-then-act routine fits the tool-hop cap (run → look → act → answer)" do
    # Routines' hop budget: run_routine spends a hop before any step runs, and a step may read
    # state before acting, so lights + thermostat + calendar is three tool rounds.
    parent = self()

    Process.put(:script, [
      [call("run_routine")],
      [call("home_status"), call("home_status"), call("get_calendar_events")],
      [call("home_control"), call("home_control")],
      []
    ])

    round_fun = fn _contents, _system, _cfg, _thinking, _target, tools? ->
      send(parent, {:round, tools?})
      [calls | rest] = Process.get(:script)
      Process.put(:script, rest)
      {:ok, calls}
    end

    cfg = %Config{tools: [], web_search: false, tool_cache: false}
    tool_ctx = %{session_id: nil, user_id: nil, config: cfg}
    Gemini.run_rounds([], "sys", cfg, "low", tool_ctx, self(), 0, round_fun)

    for _ <- 1..4, do: assert_received({:round, true})
    refute_received {:round, _}
    assert_received {:gemini_done}
  end

  test "routines_block lists each routine's name and triggers so a match goes to run_routine" do
    block =
      Gemini.routines_block(%{
        routines: [
          %{name: "good night", triggers: ["bedtime", "lights out"]},
          %{name: "leaving", triggers: []}
        ]
      })

    assert block =~ "run_routine"
    assert block =~ ~s|"good night" (or: "bedtime", "lights out")|
    assert block =~ ~s|"leaving"|
    refute block =~ ~s|"leaving" (|
  end

  test "routines_block is empty when the user has none (or the ctx has no routines)" do
    assert Gemini.routines_block(%{routines: []}) == ""
    assert Gemini.routines_block(%{}) == ""
  end

  test "routines_block strips double quotes so a phrase can't break the quoting" do
    block = Gemini.routines_block(%{routines: [%{name: ~s|the "big" one|, triggers: []}]})
    assert block =~ ~s|"the big one"|
  end
end

defmodule App.Adapters.TextModel.GeminiToolkitsTest do
  # async: false — mutates global app env (:home_assistant, req opts, the directory seam) and
  # the global Logger level.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias App.Adapters.TextModel.Gemini
  alias App.Config
  alias App.Test.HomeFixture
  alias App.Toolkits.Home

  # A stand-in run_routine (the real one needs a user + DB): returns stored steps that name the house.
  defmodule FakeRoutine do
    @behaviour App.Tools.Tool
    def declarations do
      [
        %{
          name: "run_routine",
          description: "run_routine",
          parameters: %{type: "object", properties: %{}, required: []}
        }
      ]
    end

    def execute("run_routine", _args, _ctx),
      do: {:ok, %{name: "good night", steps: "turn off the gaming lights", instructions: "do it"}}
  end

  setup do
    Application.put_env(:app, :home_assistant, %{
      url: "https://ha.example.test",
      token: "test-token"
    })

    Application.put_env(:app, :home_assistant_req_opts, plug: {Req.Test, GeminiHaStub})
    Application.put_env(:app, :home_assistant_directory, HomeFixture.directory())

    on_exit(fn ->
      Application.delete_env(:app, :home_assistant)
      Application.delete_env(:app, :home_assistant_req_opts)
      Application.delete_env(:app, :home_assistant_directory)
    end)

    Req.Test.stub(GeminiHaStub, fn conn -> Req.Test.json(conn, []) end)

    {:ok, cfg: %{Config.default() | web_search: false, tool_cache: false}}
  end

  defp call(name, args \\ %{}), do: %{name: name, args: args, sig: nil, id: nil}

  defp use_home, do: call("use_toolkit", %{"name" => "home"})

  # A round runner that plays `script` (one call list per tools-on round; [] once it runs out).
  # The script's tail may be a 0-arity fun instead — then every later round calls it, forever.
  # It reports every round's tools? flag, cfg.tools and contents, and bails after 12 rounds so a
  # broken hop rule fails the counts instead of hanging the suite.
  defp scripted(script) do
    parent = self()
    Process.put(:script, script)
    Process.put(:rounds, 0)

    fn contents, _system, cfg, _thinking, _target, tools? ->
      n = Process.get(:rounds) + 1
      Process.put(:rounds, n)
      send(parent, {:round, tools?})
      send(parent, {:cfg_tools, n, cfg.tools})
      send(parent, {:contents, n, contents})

      case {tools?, Process.get(:script)} do
        {false, _} ->
          {:ok, []}

        _ when n > 12 ->
          {:ok, []}

        {true, [calls | rest]} ->
          Process.put(:script, rest)
          {:ok, calls}

        {true, fun} when is_function(fun, 0) ->
          {:ok, fun.()}

        {true, []} ->
          {:ok, []}
      end
    end
  end

  defp run(cfg, round_fun) do
    tool_ctx = %{session_id: nil, user_id: nil, config: cfg}
    Gemini.run_rounds([], "sys", cfg, "low", tool_ctx, self(), 0, round_fun)
  end

  defp count(msg_match) do
    Stream.repeatedly(fn ->
      receive do
        msg -> if msg_match.(msg), do: :hit, else: :miss
      after
        0 -> :done
      end
    end)
    |> Enum.take_while(&(&1 != :done))
    |> Enum.count(&(&1 == :hit))
  end

  test "use_toolkit puts the kit's declarations in the NEXT round", %{cfg: cfg} do
    refute App.Tools.HomeAssistant in cfg.tools
    run(cfg, scripted([[use_home()]]))

    assert_received {:cfg_tools, 1, round1}
    refute App.Tools.HomeAssistant in round1
    assert_received {:cfg_tools, 2, round2}
    assert App.Tools.HomeAssistant in round2
    assert_received {:gemini_tool_result, "use_toolkit", _, %{opened: "home"}}
    assert_received {:gemini_done}
  end

  test "use_toolkit is plumbing: no chip, no bridge", %{cfg: cfg} do
    run(%{cfg | tool_bridges: true}, scripted([[use_home()], [call("home_status")]]))

    refute_received {:gemini_tool_call, "use_toolkit"}
    assert_received {:gemini_tool_call, "home_status"}
    assert_received {:gemini_bridge, phrase}
    assert phrase in App.Tools.HomeAssistant.bridge("home_status")
    refute_received {:gemini_bridge, _}
  end

  test "opening a kit spends no hop: three home_status rounds still run before the forced answer",
       %{cfg: cfg} do
    run(cfg, scripted([[use_home()] | fn -> [call("home_status")] end]))

    # the free use_toolkit round + 3 hop-spending home_status rounds + the capped ask, then tools-off
    for _ <- 1..5, do: assert_received({:round, true})
    assert_received {:round, false}
    refute_received {:round, _}
    assert_received {:gemini_done}
    assert count(&match?({:gemini_tool_result, "home_status", _, _}, &1)) == 3
  end

  test "re-opening an already-open kit spends a hop (and the tool context sees it open)",
       %{cfg: cfg} do
    run(cfg, scripted(fn -> [use_home()] end))

    # the first (free) open + 3 counted re-opens + the capped ask, then tools-off
    for _ <- 1..5, do: assert_received({:round, true})
    assert_received {:round, false}
    refute_received {:round, _}
    assert_received {:gemini_tool_result, "use_toolkit", _, %{opened: "home"}}
    # tool_ctx.config was widened, so use_toolkit itself reports the kit as open
    assert_received {:gemini_tool_result, "use_toolkit", _, %{already_open: "home"}}
  end

  test "a kit preselected before the turn is already open: use_toolkit spends a hop",
       %{cfg: cfg} do
    {cfg, _note} = Gemini.brain_setup("turn on the gaming lights", %{recent: []}, cfg, now())
    run(cfg, scripted(fn -> [use_home()] end))

    for _ <- 1..4, do: assert_received({:round, true})
    assert_received {:round, false}
    refute_received {:round, _}
  end

  test "an unknown toolkit name is not a free round", %{cfg: cfg} do
    run(cfg, scripted(fn -> [call("use_toolkit", %{"name" => "garage band"})] end))

    for _ <- 1..4, do: assert_received({:round, true})
    assert_received {:round, false}
    refute_received {:round, _}
  end

  test "a routine whose steps name the house opens the kit for the next round", %{cfg: cfg} do
    cfg = %{cfg | tools: [FakeRoutine, App.Tools.UseToolkit]}
    run(cfg, scripted([[call("run_routine")]]))

    assert_received {:cfg_tools, 1, round1}
    refute App.Tools.HomeAssistant in round1
    assert_received {:cfg_tools, 2, round2}
    assert App.Tools.HomeAssistant in round2
  end

  # The function responses the round-`n` request carries (the last user turn of its contents).
  defp responses_in(n) do
    assert_received {:contents, ^n, contents}
    %{role: "user", parts: parts} = List.last(contents)
    Map.new(parts, fn %{functionResponse: %{name: name, response: r}} -> {name, r} end)
  end

  test "a kit a routine opens gets its guidance in that run_routine's response", %{cfg: cfg} do
    cfg = %{cfg | tools: [FakeRoutine, App.Tools.UseToolkit]}
    run(cfg, scripted([[call("run_routine")]]))

    assert %{"run_routine" => resp} = responses_in(2)
    assert resp.toolkit =~ "Toolkit open: home"
    assert resp.toolkit =~ Home.guidance()
    assert resp.result.steps == "turn off the gaming lights"
  end

  test "a routine whose kit was already open gets no guidance again", %{cfg: cfg} do
    cfg = App.Toolkits.open(%{cfg | tools: [FakeRoutine, App.Tools.UseToolkit]}, [Home])
    run(cfg, scripted([[call("run_routine")]]))

    assert %{"run_routine" => resp} = responses_in(2)
    refute Map.has_key?(resp, :toolkit)
  end

  test "use_toolkit + a real call in one round spends the hop, and the kit is still open next",
       %{cfg: cfg} do
    run(cfg, scripted([[use_home(), call("home_status")] | fn -> [call("home_status")] end]))

    assert_received {:cfg_tools, 1, round1}
    refute App.Tools.HomeAssistant in round1
    assert_received {:cfg_tools, 2, round2}
    assert App.Tools.HomeAssistant in round2

    # the mixed round + 2 more counted rounds + the capped ask, then tools-off
    for _ <- 1..4, do: assert_received({:round, true})
    assert_received {:round, false}
    refute_received {:round, _}
  end

  test "use_toolkit + run_routine in one round: the routine refund still applies, the kit opens",
       %{cfg: cfg} do
    cfg = %{cfg | tools: [FakeRoutine, App.Tools.UseToolkit]}

    run(
      cfg,
      scripted([[use_home(), call("run_routine")] | fn -> [call("home_status")] end])
    )

    assert_received {:cfg_tools, 2, round2}
    assert App.Tools.HomeAssistant in round2

    # the mixed round refunds itself + 2: 5 more counted rounds + the capped ask, then tools-off
    for _ <- 1..7, do: assert_received({:round, true})
    assert_received {:round, false}
    refute_received {:round, _}
  end

  test "opening logs once per kit, tagged with how it opened", %{cfg: cfg} do
    prev = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: prev) end)

    brain = capture_log(fn -> run(cfg, scripted([[use_home(), use_home()], [use_home()]])) end)
    assert length(String.split(brain, "[toolkit] home opened (brain)")) == 2

    routine =
      capture_log(fn ->
        run(
          %{cfg | tools: [FakeRoutine, App.Tools.UseToolkit]},
          scripted([[call("run_routine")]])
        )
      end)

    assert routine =~ "[toolkit] home opened (routine)"

    pre =
      capture_log(fn -> Gemini.brain_setup("turn on the gaming lights", %{}, cfg, now()) end)

    assert length(String.split(pre, "[toolkit] home opened (preselect)")) == 2
  end

  describe "kits_from_round/3" do
    test "a run_routine whose steps need the house", %{cfg: cfg} do
      assert Gemini.kits_from_round(
               cfg,
               [%{name: "run_routine", args: %{}}],
               [%{result: %{steps: "turn off the gaming lights"}}]
             ) == [Home]

      # a carded/annotated response still counts
      assert Gemini.kits_from_round(
               cfg,
               [%{name: "run_routine", args: %{}}],
               [%{result: %{steps: "turn off the gaming lights"}, display: "x"}]
             ) == [Home]
    end

    test "tolerates errored and step-less routine responses", %{cfg: cfg} do
      routine = [%{name: "run_routine", args: %{}}]
      assert Gemini.kits_from_round(cfg, routine, [%{error: "timeout"}]) == []
      assert Gemini.kits_from_round(cfg, routine, [%{result: %{note: "no such routine"}}]) == []
      assert Gemini.kits_from_round(cfg, routine, [%{result: %{steps: "water the plants"}}]) == []
    end

    test "use_toolkit names an enabled kit; unknown names and open kits add nothing",
         %{cfg: cfg} do
      ok = %{result: %{opened: "home"}}
      assert Gemini.kits_from_round(cfg, [use_home()], [ok]) == [Home]
      assert Gemini.kits_from_round(cfg, [use_home(), use_home()], [ok, ok]) == [Home]

      assert Gemini.kits_from_round(cfg, [call("use_toolkit", %{"name" => "nope"})], [ok]) == []

      open = App.Toolkits.open(cfg, [Home])
      assert Gemini.kits_from_round(open, [use_home()], [ok]) == []

      assert Gemini.kits_from_round(
               open,
               [%{name: "run_routine", args: %{}}],
               [%{result: %{steps: "turn off the gaming lights"}}]
             ) == []
    end
  end

  describe "brain_setup/4" do
    test "preselects the house for a house request: tools + guidance note" do
      {cfg, note} =
        Gemini.brain_setup("turn on the gaming lights", %{recent: []}, Config.default(), now())

      assert App.Tools.HomeAssistant in cfg.tools
      assert cfg.open_toolkits == ["home"]
      assert note =~ "Toolkit open: home"
    end

    test "leaves an unrelated request alone" do
      base = Config.default()
      {cfg, note} = Gemini.brain_setup("what's the weather", %{recent: []}, base, now())

      assert note == ""
      refute App.Tools.HomeAssistant in cfg.tools
      assert cfg == base
    end
  end

  describe "the brain request (stream_brain/4)" do
    defp first_round(transcript, cfg, opts \\ []) do
      parent = self()

      round_fun = fn contents, system, round_cfg, _thinking, _target, _tools? ->
        send(parent, {:first_round, contents, system, round_cfg})
        {:ok, []}
      end

      Gemini.stream_brain(
        transcript,
        %{recent: []},
        [config: cfg, thinking: "low", round_fun: round_fun] ++ opts,
        self()
      )

      assert_received {:first_round, contents, system, round_cfg}
      assert_received {:gemini_done}
      [%{role: "user", parts: [%{text: text}]}] = contents
      {text, system, round_cfg}
    end

    test "carries the toolkit catalog in the system prompt, never the old home block or guidance",
         %{cfg: cfg} do
      {_text, system, _} = first_round("turn on the gaming lights", cfg)

      assert system =~ "use_toolkit"
      assert system =~ "home (the house:"
      refute system =~ "home_index"
      refute system =~ "home_find"
      # guidance rides the user message, never the (prefix-cached) system instruction
      refute system =~ "Toolkit open"
      refute system =~ Home.guidance()
    end

    test "the system prompt is identical whether or not a kit was preselected", %{cfg: cfg} do
      {_, house, _} = first_round("turn on the gaming lights", cfg)
      {_, weather, _} = first_round("what's the weather", cfg)
      assert house == weather
    end

    test "a preselected kit is open for round 1 and its note rides the final user message",
         %{cfg: cfg} do
      {text, _system, round_cfg} = first_round("turn on the gaming lights", cfg, quiet: true)

      assert App.Tools.HomeAssistant in round_cfg.tools
      assert String.starts_with?(text, "(Current time: ")
      assert String.ends_with?(text, "turn on the gaming lights")

      # time_note <> note <> quiet_note <> transcript
      {time_at, _} = :binary.match(text, "(Current time: ")
      {kit_at, _} = :binary.match(text, "(Toolkit open: home.")
      {quiet_at, _} = :binary.match(text, "(The user TYPED")
      assert time_at < kit_at and kit_at < quiet_at
    end

    test "an unrelated request gets no note and no house tools", %{cfg: cfg} do
      {text, _system, round_cfg} = first_round("what's the weather", cfg)

      refute text =~ "Toolkit open"
      refute App.Tools.HomeAssistant in round_cfg.tools
    end

    test "with no kit configured there is no catalog and no use_toolkit" do
      Application.delete_env(:app, :home_assistant)
      cfg = %{Config.default() | web_search: false}

      assert Gemini.toolkits_block(cfg) == ""
      {text, system, round_cfg} = first_round("turn on the gaming lights", cfg)

      refute system =~ "use_toolkit"
      refute text =~ "Toolkit open"
      refute App.Tools.HomeAssistant in round_cfg.tools
    end
  end

  test "toolkits_block is the catalog line with a leading space when a kit is enabled",
       %{cfg: cfg} do
    assert Gemini.toolkits_block(cfg) == " " <> App.Toolkits.catalog_line(cfg)
  end

  defp now, do: DateTime.utc_now()
end
