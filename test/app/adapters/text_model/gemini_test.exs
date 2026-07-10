defmodule App.Adapters.TextModel.GeminiTest do
  use ExUnit.Case, async: true
  alias App.Adapters.TextModel.Gemini
  alias App.Config

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
      {:ok, [{"noop", %{}, nil}]}
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
        {:ok, [{"sleep_a", %{}, nil}, {"sleep_b", %{}, nil}]}
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

    assert Gemini.extract_calls(decoded) == [{"get_weather", %{"location" => "STL"}, "sig-abc"}]
  end

  test "extract_calls keeps a nil signature when the part has none" do
    decoded = %{
      "candidates" => [
        %{"content" => %{"parts" => [%{"functionCall" => %{"name" => "f", "args" => %{}}}]}}
      ]
    }

    assert Gemini.extract_calls(decoded) == [{"f", %{}, nil}]
  end

  test "extract_calls is [] when there are no function calls" do
    decoded = %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "hi"}]}}]}
    assert Gemini.extract_calls(decoded) == []
  end

  test "model_call_parts echoes the thought_signature back (Gemini 3 requires it)" do
    calls = [{"get_weather", %{"location" => "STL"}, "sig-abc"}]

    assert Gemini.model_call_parts(calls) == [
             %{
               functionCall: %{name: "get_weather", args: %{"location" => "STL"}},
               thoughtSignature: "sig-abc"
             }
           ]
  end

  test "model_call_parts omits the signature key when there isn't one" do
    assert Gemini.model_call_parts([{"f", %{}, nil}]) == [
             %{functionCall: %{name: "f", args: %{}}}
           ]
  end

  test "function_response_parts builds the tool-result content parts" do
    results = [{"get_weather", %{result: %{temp_f: 70}}}]

    assert Gemini.function_response_parts(results) == [
             %{functionResponse: %{name: "get_weather", response: %{result: %{temp_f: 70}}}}
           ]
  end

  test "bridge_phrase is nil when tool_bridges is off" do
    assert Gemini.bridge_phrase([{"get_weather", %{}, nil}], %Config{tool_bridges: false}) == nil
  end

  test "bridge_phrase picks a declared phrase for a phrase-bearing call" do
    cfg = %Config{tools: [App.Tools.Weather], tool_bridges: true}
    phrase = Gemini.bridge_phrase([{"get_weather", %{}, nil}], cfg)
    assert phrase in App.Tools.Weather.bridge("get_weather")
  end

  test "bridge_phrase is nil when no call has a phrase" do
    cfg = %Config{tools: [App.Tools.Reminders], tool_bridges: true}
    assert Gemini.bridge_phrase([{"list_reminders", %{}, nil}], cfg) == nil
  end

  test "bridge_phrase picks the FIRST phrase-bearing call" do
    cfg = %Config{tools: [App.Tools.Weather, App.Tools.Calendar], tool_bridges: true}

    phrase =
      Gemini.bridge_phrase(
        [{"get_weather", %{}, nil}, {"get_calendar_events", %{}, nil}],
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

  test "brain prompt teaches the follow-up offer" do
    prompt = Gemini.brain_prompt("Henry")
    assert prompt =~ "follow-up"
    assert prompt =~ "confirm"
  end

  test "brain prompt treats email (Gmail) as a real capability, not a can't-do" do
    prompt = Gemini.brain_prompt("Henry")
    # Gmail shipped — email must NOT be listed among things Henry can't do yet.
    refute prompt =~ ~r/do yet[^.]*email/
    # and it's named as a capability.
    assert prompt =~ "email"
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
end
