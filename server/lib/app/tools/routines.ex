defmodule App.Tools.Routines do
  @moduledoc """
  Routines tool: save, list, delete and run the user's natural-language macros
  (`App.Routines`). Running one does not execute anything itself — `run_routine` hands the
  brain the stored steps plus an instruction to carry them out with its OTHER tools in the
  same turn and sum up once. The brain already knows each routine's name and triggers from
  the system prompt (`App.Memory.context/2` → `Gemini.routines_block/1`), so a matching
  utterance costs one tool round, not a list-then-run.

  Voice routing caveat: with voice activation on, the conversation layer consumes a phrase
  right after "Henry" that STARTS with a sleep word (`App.Config :sleep_words` — "lock up"
  locks him) or a stop word ("stop everything" halts him) before the brain ever hears it.
  `save_routine` drops such triggers and says so (`swallowed/2`). "Good night" is safe.
  """
  @behaviour App.Tools.Tool

  alias App.Conversations.WakeWord
  alias App.Routines

  @instructions "Carry out every step now with your tools, then give ONE short summary of " <>
                  "what you did and anything that failed."

  @impl true
  def declarations do
    [
      %{
        name: "save_routine",
        description:
          "Save (or replace, by name) one of the user's routines: a named set of steps you " <>
            "carry out with your tools whenever they say its name or a trigger phrase. Only " <>
            "after the user confirms the steps you read back.",
        parameters: %{
          type: "object",
          properties: %{
            name: %{type: "string", description: "The routine's name, e.g. \"good night\"."},
            triggers: %{
              type: "array",
              items: %{type: "string"},
              description:
                "Phrases that should run it, as the user would say them (\"bedtime\", " <>
                  "\"I'm heading out\"). The name always runs it too."
            },
            steps: %{
              type: "string",
              description:
                "Every step, written as clear imperative instructions to yourself (\"Turn off " <>
                  "the downstairs lights. Set the thermostat to 68. Tell me the first event " <>
                  "on my calendar tomorrow.\"). Max 2,000 characters."
            }
          },
          required: ["name", "steps"]
        }
      },
      %{
        name: "list_routines",
        description: "Read back the user's saved routines: name, triggers and steps.",
        parameters: %{type: "object", properties: %{}, required: []}
      },
      %{
        name: "delete_routine",
        description: "Delete one of the user's routines, by name or trigger.",
        parameters: %{
          type: "object",
          properties: %{name: %{type: "string", description: "The routine's name."}},
          required: ["name"]
        }
      },
      %{
        name: "run_routine",
        description:
          "Run one of the user's routines: returns its steps, which you then carry out with " <>
            "your other tools in this same turn.",
        parameters: %{
          type: "object",
          properties: %{
            name: %{type: "string", description: "The routine's name or the trigger they said."}
          },
          required: ["name"]
        }
      }
    ]
  end

  @impl true
  def prompt do
    "Routines are the user's saved macros: a name, trigger phrases, and steps. To create one " <>
      "(\"when I say good night, turn off the downstairs lights…\"), read the steps back in one " <>
      "sentence and call save_routine only after the user confirms, writing steps as clear " <>
      "imperative instructions to yourself. When what the user says matches one of their " <>
      "routines' names or triggers (listed at the end of this prompt), call run_routine FIRST, " <>
      "then carry out every step with your tools in the same turn — independent steps as " <>
      "parallel calls — and finish with ONE short summary. Never invent or skip steps; if a " <>
      "step needs something you can't do, say so in the summary."
  end

  @impl true
  def bridge("run_routine"), do: ["On it.", "Running it."]
  def bridge(_), do: []

  @impl true
  def execute(_name, _args, %{user_id: nil}),
    do: {:ok, %{note: "no user session — routines need a signed-in user"}}

  def execute("save_routine", %{"name" => name, "steps" => steps} = args, %{user_id: uid} = ctx)
      when is_binary(name) and is_binary(steps) do
    cfg = ctx.config
    triggers = args |> Map.get("triggers") |> List.wrap() |> Enum.filter(&is_binary/1)
    {blocked, kept} = Enum.split_with(triggers, &swallowed(&1, cfg))
    unreachable = if(swallowed(name, cfg), do: [name], else: []) ++ blocked
    replaced? = Enum.any?(Routines.list(uid), &(&1.name == Routines.match_key(name)))

    case Routines.save(uid, %{name: name, triggers: kept, steps: steps}) do
      {:ok, r} ->
        {:ok,
         put_unreachable(
           %{saved: r.label, triggers: r.triggers, steps: r.steps, replaced: replaced?},
           unreachable
         )}

      {:error, :invalid_name} ->
        {:ok, %{saved: false, note: "a routine needs a name with letters or numbers in it"}}

      {:error, {:trigger_taken, phrase, other}} ->
        {:ok,
         %{
           saved: false,
           note:
             ~s|"#{phrase}" already runs the "#{other}" routine — pick another phrase, or | <>
               "change that routine instead"
         }}

      {:error, %Ecto.Changeset{} = cs} ->
        {:ok, %{saved: false, note: changeset_note(cs)}}
    end
  end

  def execute("list_routines", _args, %{user_id: uid}) do
    case Routines.list(uid) do
      [] ->
        {:ok, %{routines: [], note: "no routines saved yet"}}

      routines ->
        {:ok,
         %{
           routines:
             Enum.map(routines, fn r ->
               %{
                 name: r.label,
                 triggers: r.triggers,
                 steps: r.steps,
                 last_run: iso(r.last_run_at)
               }
             end)
         }}
    end
  end

  def execute("delete_routine", %{"name" => name}, %{user_id: uid}) when is_binary(name) do
    case Routines.delete(uid, name) do
      {:ok, r} -> {:ok, %{deleted: r.label}}
      {:error, :not_found} -> {:ok, %{note: ~s|no routine called "#{name}" — nothing deleted|}}
    end
  end

  def execute("run_routine", %{"name" => name}, %{user_id: uid}) when is_binary(name) do
    case Routines.get(uid, name) do
      nil ->
        {:ok,
         %{
           note: ~s|no routine called "#{name}"|,
           routines: uid |> Routines.list() |> Enum.map(& &1.label)
         }}

      routine ->
        # Stamping the run is bookkeeping — it must never stop the routine itself.
        _ = Routines.mark_run(routine)
        {:ok, %{name: routine.label, steps: routine.steps, instructions: @instructions}}
    end
  end

  def execute(_name, _args, _ctx), do: {:error, :missing_args}

  @doc false
  # Would the conversation layer consume `phrase` (said right after "Henry") before the brain
  # hears it? `:sleep` — it starts with a sleep word and locks him; `:stop` — it starts with a
  # stop word and halts him (the tail after the stop word is all that would reach the brain).
  # nil — it reaches the brain intact. Mirrors Conversation.handle_gated_endpoint/2's routing.
  def swallowed(phrase, cfg) do
    cond do
      WakeWord.sleep_command?(phrase, cfg) -> :sleep
      WakeWord.command_rest(phrase) != :none -> :stop
      true -> nil
    end
  end

  defp put_unreachable(result, []), do: result

  defp put_unreachable(result, phrases) do
    quoted = Enum.map_join(phrases, ", ", &~s|"#{&1}"|)

    Map.merge(result, %{
      unreachable: phrases,
      note:
        "#{quoted} can't run this by voice: said after your name, a phrase that starts with " <>
          "a stop or sleep word (stop, wait, lock, sleep…) halts or locks you before it " <>
          "reaches you, so it isn't kept as a trigger. Suggest the user pick a different phrase."
    })
  end

  defp changeset_note(cs) do
    errors = Ecto.Changeset.traverse_errors(cs, fn {msg, _opts} -> msg end)

    cond do
      Map.has_key?(errors, :steps) and Map.get(cs.changes, :steps) ->
        "the steps are too long (2,000 characters max) — tighten them and try again"

      Map.has_key?(errors, :steps) ->
        "a routine needs at least one step"

      Map.has_key?(errors, :label) ->
        "that name is too long — keep it under 80 characters"

      true ->
        "couldn't save that routine"
    end
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
