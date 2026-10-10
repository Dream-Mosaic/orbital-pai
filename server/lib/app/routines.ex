defmodule App.Routines do
  @moduledoc """
  Routines: per-user, natural-language macros ("when I say *good night*, turn off the
  downstairs lights, set the thermostat to 68 and tell me what's first tomorrow"). Henry's
  brain executes the steps with its existing tools — this is storage and matching, not a
  rules engine.

  Matching is forgiving on purpose: a routine is found by its name OR any trigger, ignoring
  case, punctuation, spacing, a leading "my/our/the" and a trailing "routine" — so
  "Good night!", "goodnight" and "my good-night routine" are the same routine
  (`match_key/1`). Saving under an existing name replaces that routine; a trigger another of
  the user's routines already answers to is refused, so one phrase never runs two routines.
  """
  import Ecto.Query
  alias App.Repo
  alias App.Routines.Routine

  @max_triggers 10
  @max_trigger_len 100

  @doc """
  Create or replace (by name) one of `user_id`'s routines. `attrs` carries `name` (as said),
  `steps` (imperative instructions, ≤ 2,000 chars) and optional `triggers` (phrases) — atom
  or string keys. Returns `{:ok, routine}`, `{:error, :invalid_name}`,
  `{:error, {:trigger_taken, phrase, other_label}}` or `{:error, changeset}`.
  """
  def save(user_id, attrs) do
    label = attrs |> attr(:name) |> clean()
    key = match_key(label)
    triggers = attrs |> attr(:triggers) |> clean_triggers()

    if key == "" do
      {:error, :invalid_name}
    else
      with :ok <- check_conflicts(user_id, key, [label | triggers]) do
        (Repo.get_by(Routine, user_id: user_id, name: key) || %Routine{})
        |> Routine.changeset(%{
          user_id: user_id,
          name: key,
          label: label,
          triggers: triggers,
          steps: attrs |> attr(:steps) |> clean()
        })
        |> Repo.insert_or_update()
      end
    end
  end

  @doc "All of `user_id`'s routines, alphabetical by label."
  def list(user_id) do
    Routine
    |> where([r], r.user_id == ^user_id)
    |> Repo.all()
    |> Enum.sort_by(&String.downcase(&1.label))
  end

  @doc """
  Name + triggers (never steps) of `user_id`'s routines, alphabetical — the cheap shape the
  brain's system prompt lists so it knows a routine exists without a tool round. Triggers that
  merely repeat the name are dropped (the name already runs it).
  """
  def brief(user_id) do
    from(r in Routine,
      where: r.user_id == ^user_id,
      select: %{key: r.name, name: r.label, triggers: r.triggers}
    )
    |> Repo.all()
    |> Enum.sort_by(&String.downcase(&1.name))
    |> Enum.map(fn %{key: key, name: name, triggers: triggers} ->
      %{name: name, triggers: Enum.reject(triggers, &(match_key(&1) == key))}
    end)
  end

  @doc """
  The routine of `user_id`'s whose name (preferred) or any trigger matches `phrase`
  (`match_key/1`-insensitive), or nil.
  """
  def get(user_id, phrase) do
    case match_key(phrase) do
      "" ->
        nil

      key ->
        routines = list(user_id)

        Enum.find(routines, &(&1.name == key)) ||
          Enum.find(routines, fn r -> Enum.any?(r.triggers, &(match_key(&1) == key)) end)
    end
  end

  @doc "Delete the routine `phrase` names (by name or trigger). `{:error, :not_found}` if none."
  def delete(user_id, phrase) do
    case get(user_id, phrase) do
      nil -> {:error, :not_found}
      routine -> Repo.delete(routine)
    end
  end

  @doc "Stamp `last_run_at` = now."
  def mark_run(%Routine{} = routine) do
    routine
    |> Routine.changeset(%{last_run_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> Repo.update()
  end

  @doc false
  # The identity a routine is matched and replaced by: lowercase, apostrophes dropped, every
  # other non-alphanumeric run removed, minus a leading "my/our/the" and a trailing "routine".
  def match_key(phrase) when is_binary(phrase) do
    phrase
    |> String.downcase()
    |> String.replace(~r/['’]/u, "")
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
    |> String.replace(~r/\A(?:my|our|the)\s+/u, "")
    |> String.replace(~r/\s+routine\z/u, "")
    |> String.replace(" ", "")
  end

  def match_key(_), do: ""

  # A phrase this routine would answer to that ANOTHER of the user's routines already does.
  defp check_conflicts(user_id, key, phrases) do
    others = user_id |> list() |> Enum.reject(&(&1.name == key))

    Enum.find_value(phrases, :ok, fn phrase ->
      k = match_key(phrase)

      case Enum.find(others, fn o ->
             o.name == k or Enum.any?(o.triggers, &(match_key(&1) == k))
           end) do
        nil -> nil
        other -> {:error, {:trigger_taken, phrase, other.label}}
      end
    end)
  end

  defp clean_triggers(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(&1 |> clean() |> String.slice(0, @max_trigger_len)))
    |> Enum.reject(&(match_key(&1) == ""))
    |> Enum.uniq_by(&match_key/1)
    |> Enum.take(@max_triggers)
  end

  defp clean_triggers(_), do: []

  defp clean(s) when is_binary(s), do: String.trim(s)
  defp clean(_), do: ""

  defp attr(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
end
