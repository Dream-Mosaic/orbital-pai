defmodule App.Adapters.TextModel.Gemini do
  @moduledoc """
  Gemini 3 Flash via the Google Generative Language API. Thinking is the latency
  lever: `minimal` for the reflex (instant lead-in), `low` for the brain.

  Verified 2026-06-14: model `gemini-3-flash-preview`, `x-goog-api-key` header,
  `generationConfig.thinkingConfig.thinkingLevel`. Re-check the model id (preview
  suffixes change) before relying on it.
  """
  @behaviour App.Adapters.TextModel

  require Logger

  # Safety valve: stop looping after this many tool round-trips in one turn.
  @max_tool_hops 3

  @impl true
  def generate(transcript, ctx, opts) do
    cfg = Keyword.fetch!(opts, :config)
    tier = Keyword.fetch!(opts, :tier)
    thinking = Keyword.fetch!(opts, :thinking)

    body = %{
      systemInstruction: %{parts: [%{text: system_for(tier, cfg, ctx)}]},
      contents: build_contents(ctx, transcript),
      generationConfig: %{
        thinkingConfig: %{thinkingLevel: thinking},
        # Thinking tokens count against this budget, so the memory tier (summary + facts,
        # which think before writing) needs extra headroom or it truncates mid-sentence.
        maxOutputTokens: max_output_tokens(tier)
      }
    }

    url =
      "https://generativelanguage.googleapis.com/v1beta/models/#{model_for(tier, cfg)}:generateContent"

    case Req.post(url,
           finch: App.Finch,
           headers: [{"x-goog-api-key", System.fetch_env!("GOOGLE_API_KEY")}],
           json: body,
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: resp}} -> {:ok, extract_text(resp)}
      {:ok, %{status: s, body: b}} -> {:error, {:http, s, b}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stream a brain reply token-by-token (SSE), running any tool calls inline. Sends `target`:
  `{:gemini_delta, text}` per text delta, then `{:gemini_done}` — or `{:gemini_error, reason}`.
  A tool round just looks like a pause before deltas arrive (no new message types). Blocks
  the caller, so run it in a task.
  """
  def stream_brain(transcript, ctx, opts, target) do
    cfg = Keyword.fetch!(opts, :config)
    thinking = Keyword.fetch!(opts, :thinking)
    sid = Keyword.get(opts, :session_id)
    image = Keyword.get(opts, :image)
    tool_ctx = %{session_id: sid, user_id: App.Users.id_from_session(sid), config: cfg}

    system = system_for(:brain, cfg, ctx)
    contents = build_contents(ctx, time_note(cfg) <> transcript, image)
    run_rounds(contents, system, cfg, thinking, tool_ctx, target, 0)
  end

  @doc false
  # `round_fun` is injectable for tests; in production it's `stream_round/6`. Its 6th arg is
  # `tools?` — true on normal rounds, false on the forced final round (see the cap branch).
  def run_rounds(
        contents,
        system,
        cfg,
        thinking,
        tool_ctx,
        target,
        hops,
        round_fun \\ &stream_round/6
      ) do
    case round_fun.(contents, system, cfg, thinking, target, true) do
      {:error, reason} ->
        send(target, {:gemini_error, reason})

      {:ok, []} ->
        send(target, {:gemini_done})

      {:ok, _calls} when hops >= @max_tool_hops ->
        # Out of tool budget but the model still wants to call tools — rather than end the turn
        # silently (the prod empty-brain bug), run ONE final round with tools DISABLED so it must
        # answer with what it already gathered (e.g. "I couldn't reach your calendar just now").
        Logger.warning("[gemini] tool-hop cap reached; forcing a final tools-off answer")

        case round_fun.(contents, system, cfg, thinking, target, false) do
          {:error, reason} -> send(target, {:gemini_error, reason})
          _ -> send(target, {:gemini_done})
        end

      {:ok, calls} ->
        # announce each call so the UI can show a live "checking your calendar…" chip
        Enum.each(calls, fn {name, _args, _sig} -> send(target, {:gemini_tool_call, name}) end)

        if phrase = bridge_phrase(calls, cfg), do: send(target, {:gemini_bridge, phrase})

        # Gemini can emit several calls in one round (parallel function calling) — run them
        # concurrently. ordered: true keeps results aligned with `calls` for the
        # functionResponse parts. 20s > the largest per-tool cap (Gmail 18s), so on_timeout
        # only fires if a tool's own cap machinery wedged.
        results =
          calls
          |> Task.async_stream(
            fn {name, args, _sig} ->
              case App.Tools.execute(name, args, tool_ctx) do
                {:ok, r} ->
                  {name, %{result: r}}

                {:error, e} ->
                  # Proves the failure path: the brain SEES this error and (via B1/B2) must
                  # still answer rather than loop silently. Correlate with the turn's final
                  # `brain:` line.
                  Logger.warning(
                    "[gemini] tool #{name} errored: #{error_string(e)} — fed back to brain"
                  )

                  {name, %{error: error_string(e)}}
              end
            end,
            max_concurrency: 4,
            ordered: true,
            timeout: 20_000,
            on_timeout: :kill_task
          )
          |> Enum.zip(calls)
          |> Enum.map(fn
            {{:ok, result}, _call} ->
              result

            {{:exit, reason}, {name, _args, _sig}} ->
              Logger.warning("[gemini] tool #{name} task exited: #{inspect(reason)}")
              {name, %{error: "timeout"}}
          end)

        contents =
          contents ++
            [%{role: "model", parts: model_call_parts(calls)}] ++
            [%{role: "user", parts: function_response_parts(results)}]

        run_rounds(contents, system, cfg, thinking, tool_ctx, target, hops + 1, round_fun)
    end
  end

  # One SSE round: streams text deltas to `target`, returns {:ok, function_calls} | {:error, reason}.
  # `tools?` false omits the tools block entirely, forcing the model to produce a spoken answer.
  defp stream_round(contents, system, cfg, thinking, target, tools?) do
    body =
      %{
        systemInstruction: %{parts: [%{text: system}]},
        contents: contents,
        generationConfig: %{
          thinkingConfig: %{thinkingLevel: thinking},
          maxOutputTokens: max_output_tokens(:brain)
        }
      }
      |> maybe_put_tools(cfg, tools?)

    url =
      "https://generativelanguage.googleapis.com/v1beta/models/#{cfg.model_brain}:streamGenerateContent?alt=sse"

    Process.put(:sse_buf, "")
    Process.put(:sse_calls, [])
    Process.put(:sse_finish, nil)
    Process.put(:sse_text_len, 0)

    result =
      Req.post(url,
        finch: App.Finch,
        headers: [{"x-goog-api-key", System.fetch_env!("GOOGLE_API_KEY")}],
        json: body,
        into: fn {:data, data}, acc ->
          Process.put(:sse_buf, sse_consume(Process.get(:sse_buf, "") <> data, target))
          {:cont, acc}
        end,
        # receive_timeout is the gap *between* SSE chunks, so it stays generous. Note there's
        # no global turn budget across tool rounds (up to @max_tool_hops of these + each tool's
        # own cap) — we rely on tools being fast; revisit if a global deadline is needed.
        receive_timeout: 30_000
      )

    emit_line(Process.get(:sse_buf, ""), target)
    calls = Process.get(:sse_calls, [])
    log_finish(Process.get(:sse_finish), calls)

    # Per-round outcome — proves what each brain round produced: spoken text vs. tool calls vs.
    # an empty round (0 calls + 0 chars = the model returned nothing). `tools=false` marks the
    # forced final answer round (B1).
    Logger.info(
      "[gemini] round: #{length(calls)} calls, #{Process.get(:sse_text_len, 0)} chars, " <>
        "tools=#{tools?}, finish=#{inspect(Process.get(:sse_finish))}"
    )

    case result do
      {:ok, %{status: 200}} -> {:ok, calls}
      {:ok, %{status: s}} -> {:error, {:http, s}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  # Force tools off (the final answer round must not call a tool) vs. the normal tools-on body.
  def maybe_put_tools(body, _cfg, false), do: body
  def maybe_put_tools(body, cfg, true), do: maybe_put_tools(body, cfg)

  @doc false
  def maybe_put_tools(body, cfg) do
    case tools_block(cfg) do
      nil ->
        body

      tools ->
        body = Map.put(body, :tools, tools)
        # Gemini 3 rejects (400) a built-in tool (Google-Search grounding) in the same request as
        # our function declarations UNLESS we opt in here. Verified live: without it every brain
        # turn 400s and falls back to the tool-less batch brain.
        if cfg.web_search,
          do: Map.put(body, :toolConfig, %{includeServerSideToolInvocations: true}),
          else: body
    end
  end

  @doc false
  # The `tools` array for the brain request: our function declarations (when any tool is enabled)
  # plus Google-Search grounding (when `web_search` is on). Returns nil when neither applies.
  def tools_block(cfg) do
    fn_tools =
      case App.Tools.declarations(cfg) do
        [%{functionDeclarations: []}] -> []
        decls -> decls
      end

    search = if cfg.web_search, do: [%{googleSearch: %{}}], else: []

    case fn_tools ++ search do
      [] -> nil
      tools -> tools
    end
  end

  @doc false
  # The per-turn dynamic time line. It rides the FINAL user message, not the system instruction —
  # a per-second timestamp in the system prompt busts Gemini's implicit prefix cache every turn
  # (persona + tools + history all re-tokenize). LOCAL-first (with UTC alongside) so the brain
  # judges calendar events by the right instant (preserves the timezone grounding fix); the static
  # "how to compare/convert" guidance lives in brain_prompt/1.
  def time_note(cfg) do
    utc = DateTime.utc_now() |> DateTime.truncate(:second)

    local =
      case DateTime.shift_zone(utc, cfg.timezone) do
        {:ok, dt} -> dt
        _ -> utc
      end

    "(Current time: #{DateTime.to_iso8601(local)} (#{cfg.timezone}). In UTC that is " <>
      "#{DateTime.to_iso8601(utc)}.)\n"
  end

  defp error_string(reason) when is_binary(reason), do: reason
  defp error_string(reason), do: inspect(reason)

  # Emit text for each complete line in `buf` (Gemini puts one JSON per `data:` line);
  # return the trailing partial line. Tolerant of \r\n.
  defp sse_consume(buf, target) do
    lines = buf |> String.replace("\r\n", "\n") |> String.split("\n")
    {complete, leftover} = Enum.split(lines, -1)
    Enum.each(complete, &emit_line(&1, target))
    List.first(leftover, "")
  end

  defp emit_line("data:" <> rest, target) do
    with json when json != "" <- String.trim(rest),
         {:ok, decoded} <- Jason.decode(json) do
      # We forward text deltas immediately (low-latency streaming) AND collect any
      # functionCall parts. We assume a given round is EITHER spoken text OR a tool call,
      # not both — Gemini Flash separates them in practice. If a round ever interleaved
      # preamble text before a functionCall, that text would be spoken before the tool
      # result (a mild "let me check…" filler, not a correctness bug).
      text = raw_text(decoded)

      if text != "" do
        send(target, {:gemini_delta, text})
        Process.put(:sse_text_len, Process.get(:sse_text_len, 0) + String.length(text))
      end

      if fr = finish_reason(decoded), do: Process.put(:sse_finish, fr)

      case extract_calls(decoded) do
        [] -> :ok
        calls -> Process.put(:sse_calls, Process.get(:sse_calls, []) ++ calls)
      end
    else
      _ -> :ok
    end
  end

  defp emit_line(_line, _target), do: :ok

  @doc false
  # Gemini puts the round's stop cause on the first candidate (only on the final chunk).
  def finish_reason(%{"candidates" => [%{"finishReason" => fr} | _]}), do: fr
  def finish_reason(_), do: nil

  # A normal round ends with "STOP". Anything else (notably MAX_TOKENS — thinking ate the budget,
  # which can yield an EMPTY answer) is worth a warning so the logs explain a silent/short reply.
  defp log_finish(nil, _calls), do: :ok
  defp log_finish("STOP", _calls), do: :ok

  defp log_finish(reason, calls),
    do: Logger.warning("[brain] finishReason=#{reason} (#{length(calls)} tool calls this round)")

  @doc false
  # The brain gets the recent turns as real multi-turn dialogue so it has short-term
  # memory of the exchange (the rolling summary only covers older context and lags a
  # turn). The reflex/memory tiers pass `ctx = %{}`, so they get only the current line.
  def build_contents(ctx, transcript, image \\ nil)

  def build_contents(%{recent: recent}, transcript, image) when is_list(recent) do
    history =
      recent
      |> Enum.filter(&(present?(&1.user_text) and present?(&1.brain_text)))
      |> Enum.flat_map(fn t ->
        user_text =
          case age_marker(Map.get(t, :inserted_at), DateTime.utc_now()) do
            nil -> t.user_text
            marker -> marker <> " " <> t.user_text
          end

        [
          %{role: "user", parts: [%{text: user_text}]},
          %{role: "model", parts: [%{text: t.brain_text}]}
        ]
      end)

    history ++ [user_message(transcript, image)]
  end

  def build_contents(_ctx, transcript, image), do: [user_message(transcript, image)]

  # The final user message: text alone, or text + one inline JPEG (the "look at this" frame).
  defp user_message(transcript, nil), do: %{role: "user", parts: [%{text: transcript}]}

  defp user_message(transcript, image) when is_binary(image) do
    %{
      role: "user",
      parts: [%{text: transcript}, %{inlineData: %{mimeType: "image/jpeg", data: image}}]
    }
  end

  defp present?(s), do: is_binary(s) and String.trim(s) != ""

  @doc false
  # Relative-age marker for a history turn, so the brain can tell "just now" from "yesterday".
  def age_marker(nil, _now), do: nil

  def age_marker(inserted_at, now) do
    mins = div(DateTime.diff(now, inserted_at, :second), 60)

    cond do
      mins < 15 -> nil
      mins < 120 -> "[#{mins}m ago]"
      mins < 36 * 60 -> "[#{div(mins, 60)}h ago]"
      true -> "[on #{Date.to_iso8601(DateTime.to_date(inserted_at))}]"
    end
  end

  # Per-tier model: the fast reflex/bridge model vs the smarter brain model (memory summaries want
  # the smarter one too, so they ride model_brain).
  defp model_for(:reflex, cfg), do: cfg.model_reflex
  defp model_for(_brain_or_memory, cfg), do: cfg.model_brain

  defp max_output_tokens(:reflex), do: 24
  defp max_output_tokens(:memory), do: 1024
  # Generous: the brain THINKS (thinking tokens count here) AND may run a tool round before its
  # spoken answer; 512 occasionally got eaten by thinking → MAX_TOKENS → empty reply.
  defp max_output_tokens(_brain), do: 2048

  defp system_for(:reflex, cfg, _ctx), do: reflex_prompt(cfg.name)
  defp system_for(:brain, cfg, ctx), do: brain_prompt(cfg.name) <> memory_block(ctx)

  defp system_for(:memory, _cfg, _ctx),
    do: "You maintain a concise rolling memory of a user and conversation."

  defp reflex_prompt(name) do
    ~s|You are #{name}. This is ONLY your instant first beat — the quick sound you make the second they finish, before the real reply. HARD RULES: at most 4 words; a fragment, not a sentence; don't answer, explain, or invent anything. Keep it dry and a touch wry, in character (a terse, faintly sarcastic assistant). VARY it every time. Plain words only. Improvise; don't copy: "On it—", "Hm.", "Sure—", "Right—", "Noted.", "Oh?", "Lovely.".|
  end

  @doc false
  def brain_prompt(name) do
    ~s|You are #{name}, a sharp personal assistant: terse, a little sarcastic, quick to the point when handling tasks. Talk like a real person — contractions, zero corporate filler — but you are an ASSISTANT, not a buddy with a life. NEVER invent hobbies, feelings, or things you did ("I was just reading about…", "I love…", "that keeps me up at night") — don't fake stuff like that. Answer in a sentence or two. You have a few real tools: check the weather, set or list reminders, and read the user's Google Calendar and create calendar events across their connected accounts, search, read, and send email across their connected Gmail accounts, and look up current or general info on the web — use them when the user asks for something they cover, and never claim you did something a tool didn't actually do. You can also search your own past conversations with recall_memory when the user references something from before — recall, don't guess. You can SEE through the user's camera: when they show you something or ask you to look at it or take a picture of it, a photo from their camera is attached to their message — answer about what's actually in it, and never claim you can't see or can't access the camera (if a note says the camera wasn't available this time, just say so briefly). Before creating an event, read the details back (title, time, which calendar) and wait for the user to confirm; new events go to their default account unless they name another. For reminders in a shared household: if they say "remind us / the house" set the reminder's `for` to "household"; if they name someone ("remind Tanya…") set `for` to that name; otherwise it's just for them. Read back who it's for from the tool's `assigned_to` ("okay — a shared reminder to take the bins out"). Same for email: read the recipient, subject, and body back and get the user's OK before you send. When the user mentions waiting on someone or something, or a commitment worth checking back on, you may OFFER a follow-up ("Want me to check back Thursday?") — create it with create_followup only after they agree to what and when, and don't re-offer for the same topic. For things you genuinely can't do yet (smart home), say so — briefly and dryly. Use your own tools for what they cover (weather, reminders, calendar) rather than searching the web for those. A little wry playfulness is fine; gushing, fake enthusiasm, and assistant-speak ("happy to help", "as an AI", "let me know if you need anything") are not. When an answer is genuinely structured (a recipe, a comparison, step-by-steps) you may use light markdown — bold, and short bullet or numbered lists — but keep normal replies plain and conversational. The current time (local, with UTC) is given at the top of the user's latest message; calendar events carry their own UTC offset, so to judge whether one is past or upcoming, compare it to now by absolute instant — never by wall-clock digits. When the user gives a relative or local time ("in 20 minutes", "at 5pm", "today"), compute the absolute moment(s) and pass ISO8601 UTC (e.g. 2026-06-16T22:00:00Z) — as due_at for create_reminder, as time_min/time_max for get_calendar_events, or as start/end for create_event. Conversely, when you tell the user about a time, say it naturally in their local timezone ("2pm", "tomorrow morning") — never read out a UTC timestamp.|
  end

  @doc false
  # Identity + background notes. Identity renders even with empty notes — cold-start Henry
  # must know who he's talking to without waiting for a fact to be extracted.
  def memory_block(%{user_name: name} = ctx) when is_binary(name) and name != "" do
    "\n\nYou're speaking with #{name}." <> notes_block(ctx)
  end

  def memory_block(ctx), do: notes_block(ctx)

  defp notes_block(%{profile: p, summary: s}) when is_binary(p) or is_binary(s) do
    case String.trim("#{p || ""}\n#{s || ""}") do
      "" ->
        ""

      notes ->
        "\n\nBackground notes (may be incomplete or outdated — defer to what the user " <>
          "actually says now; never invent shared history or defend a wrong assumption):\n" <>
          notes
    end
  end

  defp notes_block(_), do: ""

  # Trimmed — for the whole batch response.
  defp extract_text(resp), do: resp |> raw_text() |> String.trim()

  # Untrimmed — for streaming deltas, where trimming would drop the spaces *between*
  # tokens and run words together ("inchesevery").
  defp raw_text(%{"candidates" => [%{"content" => %{"parts" => parts}} | _]}) do
    parts |> Enum.map(& &1["text"]) |> Enum.reject(&is_nil/1) |> Enum.join()
  end

  defp raw_text(_), do: ""

  @doc false
  # Each call is `{name, args, thought_signature}`. Gemini 3 thinking models attach a
  # `thoughtSignature` (a part-level sibling of `functionCall`) that MUST be echoed back in
  # the continuation's model turn, or the next request 400s ("missing a thought_signature").
  def extract_calls(%{"candidates" => [%{"content" => %{"parts" => parts}} | _]})
      when is_list(parts) do
    parts
    |> Enum.filter(& &1["functionCall"])
    |> Enum.map(fn part ->
      fc = part["functionCall"]
      {fc["name"], fc["args"] || %{}, part["thoughtSignature"]}
    end)
  end

  def extract_calls(_), do: []

  @doc false
  def model_call_parts(calls) do
    Enum.map(calls, fn {name, args, sig} ->
      part = %{functionCall: %{name: name, args: args}}
      if sig, do: Map.put(part, :thoughtSignature, sig), else: part
    end)
  end

  @doc false
  def function_response_parts(results) do
    Enum.map(results, fn {name, response} ->
      %{functionResponse: %{name: name, response: response}}
    end)
  end

  @doc false
  # The bridge phrase to speak before running `calls` (nil when disabled or no call declares one).
  # First phrase-bearing call wins; a random variant is chosen for light variety.
  def bridge_phrase(_calls, %{tool_bridges: false}), do: nil

  def bridge_phrase(calls, cfg) do
    Enum.find_value(calls, fn {name, _args, _sig} ->
      case App.Tools.bridge(name, cfg) do
        [] -> nil
        phrases -> Enum.random(phrases)
      end
    end)
  end
end
