defmodule App.Memory.Updater do
  @moduledoc """
  After each turn: recompute the rolling summary AND extract durable profile facts the
  user stated about themselves (source: "auto"), then prune auto-facts. Synchronous and
  side-effecting; the `Conversation` runs it off the hot path with single-flight.
  """
  alias App.Memory

  @spec run(String.t()) :: :ok
  def run(session_id) do
    # A session is keyed by `to_string(user.id)`; if it isn't a real user id (e.g. a test
    # placeholder), there's no user to scope memory to — skip rather than crash this task.
    case App.Users.id_from_session(session_id) do
      nil -> :ok
      user_id -> run(session_id, user_id)
    end
  end

  defp run(session_id, user_id) do
    ctx = Memory.context(session_id)

    case text_model().generate(summary_prompt(ctx), %{},
           tier: :memory,
           config: App.Config.default(),
           thinking: "low"
         ) do
      {:ok, summary} when is_binary(summary) and summary != "" ->
        Memory.put_summary(user_id, cap(summary))

      _ ->
        :ok
    end

    extract_facts(user_id, ctx)
    Memory.prune_auto_facts(user_id)
    # Let any open LiveView reflect the freshly-rewritten summary / facts.
    Memory.broadcast_updated()
    :ok
  end

  # "Knows me": pull NEW durable facts the user stated about themselves and store them as
  # auto-facts, deduped against what we already know (the user can edit/delete these in UI).
  defp extract_facts(user_id, ctx) do
    known = Memory.list_facts(user_id) |> Enum.map(&normalize(&1.content)) |> MapSet.new()

    case text_model().generate(facts_prompt(ctx), %{},
           tier: :memory,
           config: App.Config.default(),
           thinking: "low"
         ) do
      {:ok, text} when is_binary(text) ->
        text
        |> parse_facts()
        |> Enum.reject(&MapSet.member?(known, normalize(&1)))
        |> Enum.uniq_by(&normalize/1)
        |> Enum.each(&Memory.create_fact(%{content: &1, source: "auto", user_id: user_id}))

      _ ->
        :ok
    end
  end

  defp parse_facts(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(fn line -> line |> String.replace(~r/^[-*\d.\s]+/, "") |> String.trim() end)
    |> Enum.reject(&(&1 == "" or String.upcase(&1) == "NONE"))
    # ignore anything implausibly long for a single atomic fact
    |> Enum.filter(&(String.length(&1) <= 120))
  end

  defp normalize(s), do: s |> String.downcase() |> String.trim()

  # The summary is fed back into itself every turn and injected into every prompt, so
  # bound it server-side (the <=120-word prompt rule is advisory) to stop runaway growth.
  @summary_word_cap 160
  defp cap(summary) do
    words = String.split(summary, ~r/\s+/, trim: true)

    if length(words) <= @summary_word_cap,
      do: summary,
      else: words |> Enum.take(@summary_word_cap) |> Enum.join(" ")
  end

  defp summary_prompt(ctx) do
    """
    You maintain a concise, FACTUAL memory of a user for a voice assistant.

    Current memory:
    #{ctx.summary}

    Recent exchanges (User = the person; Assistant = you, the system):
    #{format_recent(ctx)}

    Rewrite the memory in <= 120 words. Strict rules:
    - Record ONLY durable facts the USER explicitly stated about themselves (name,
      preferences, what they're working on) and concrete topics the USER raised.
    - NEVER record the Assistant's own guesses, suggestions, or speculation as fact.
    - If a prior note was a misunderstanding the user pushed back on, DROP it — don't
      defend or repeat it.
    - Do not invent, infer, or embellish. If little was actually established, keep it
      short or return nothing.
    Plain text only, written about the user.
    """
  end

  defp facts_prompt(ctx) do
    """
    Extract NEW durable facts the USER stated about THEMSELVES from the recent exchanges
    — their name, preferences, what they're working on, relationships, recurring plans.

    Already known (do NOT repeat these):
    #{ctx.profile}

    Recent exchanges (User = the person; Assistant = you, the system):
    #{format_recent(ctx)}

    Rules:
    - Only facts the USER explicitly stated — NEVER the assistant's guesses or your own claims.
    - One fact per line, atomic, <= 12 words, written about the user (no bullets/numbering).
    - Skip anything already known above. If there's nothing genuinely new, output: NONE
    """
  end

  defp format_recent(ctx) do
    ctx.recent
    |> Enum.map(fn t -> "User: #{t.user_text}\nAssistant: #{t.brain_text}" end)
    |> Enum.join("\n")
  end

  defp text_model, do: Application.fetch_env!(:app, :text_model)
end
