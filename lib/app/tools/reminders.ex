defmodule App.Tools.Reminders do
  @moduledoc """
  The reminders tool: functions the brain can call. `create_reminder` takes an ISO8601
  UTC `due_at` (the model resolves relative times from the 'Current time' line in its
  prompt — we do no NL date parsing) and an optional `recurrence` rule ("every Tuesday",
  "every 3 days") where `due_at` is the FIRST occurrence; a malformed rule degrades to a
  one-shot with a narrated note. `cancel_reminder` ends an upcoming or repeating reminder
  by phrase (`Reminders.find_active/2` + delete). `list_reminders` reads upcoming ones
  (each tagged with `kind`). `create_followup` is the same shape as `create_reminder` but
  marks `kind: "followup"` with an optional `context` line — an open loop the brain
  offered to check back on.
  """
  @behaviour App.Tools.Tool

  alias App.Reminders
  alias App.Reminders.Target
  alias App.Users

  @valid_freqs ~w(daily weekly monthly yearly)
  @valid_days ~w(sun mon tue wed thu fri sat)

  @impl true
  def declarations do
    [
      %{
        name: "create_reminder",
        description: "Create a reminder that fires at a specific time.",
        parameters: %{
          type: "object",
          properties: %{
            body: %{
              type: "string",
              description:
                "A short task phrase for what to remind the user to DO, as an imperative " <>
                  "(e.g. \"call mom\", \"check the weather\", \"take out the trash\") — not a " <>
                  "verbatim quote of what they said."
            },
            due_at: %{
              type: "string",
              description: "When to fire, ISO8601 UTC (e.g. 2026-06-16T22:00:00Z)."
            },
            for: %{
              type: "string",
              description:
                "Who the reminder is for. Omit for the current user. Use \"household\" when they " <>
                  "say remind US / we / both / the house. Use a person's name (\"David\"/\"Tanya\") " <>
                  "when they name someone else."
            },
            recurrence: %{
              type: "object",
              description:
                "ONLY for repeating reminders (\"every Tuesday\", \"water every 3 days\", " <>
                  "\"the 1st of every month\"). due_at is then the FIRST occurrence and this " <>
                  "object is the repeat rule. Omit entirely for one-time reminders.",
              properties: %{
                freq: %{
                  type: "string",
                  enum: ["daily", "weekly", "monthly", "yearly"],
                  description: "The repeat unit."
                },
                interval: %{
                  type: "integer",
                  description: "Every N units (\"every 3 days\" → 3). Default 1."
                },
                byday: %{
                  type: "array",
                  items: %{type: "string"},
                  description:
                    "Weekly only: weekday(s) it fires, lowercase 3-letter codes " <>
                      "(sun mon tue wed thu fri sat), e.g. [\"tue\"]. Omit to repeat on " <>
                      "due_at's own weekday."
                },
                until: %{
                  type: "string",
                  description:
                    "Optional inclusive end, ISO8601 UTC (\"every day this week\" → that Sunday)."
                },
                count: %{
                  type: "integer",
                  description:
                    "Optional total number of times to fire (\"remind me 3 times\" → 3)."
                }
              },
              required: ["freq"]
            }
          },
          required: ["body", "due_at"]
        }
      },
      %{
        name: "list_reminders",
        description: "List the user's upcoming (not-yet-fired) reminders.",
        parameters: %{type: "object", properties: %{}, required: []}
      },
      %{
        name: "acknowledge_reminder",
        description:
          "Mark a reminder the USER just confirmed (\"got it\", \"done\", \"already did it\") as " <>
            "acknowledged, so it stops being pending. Call this ONLY when the user themselves " <>
            "confirms — in their words, not yours. Delivering or reading out a reminder is not " <>
            "acknowledging it; never call this on your own initiative.",
        parameters: %{
          type: "object",
          properties: %{
            reminder: %{
              type: "string",
              description:
                "The short task phrase of the reminder being confirmed (e.g. \"take out the trash\")."
            }
          },
          required: ["reminder"]
        }
      },
      %{
        name: "create_followup",
        description:
          "Create a follow-up: something to check back on later (an open loop — waiting on a " <>
            "reply, a delivery, a decision). Offer it when the user mentions one, and CONFIRM " <>
            "what + when with them before calling this.",
        parameters: %{
          type: "object",
          properties: %{
            body: %{
              type: "string",
              description:
                "What to check on, as an imperative (e.g. \"check whether Bob replied about " <>
                  "the contract\")."
            },
            due_at: %{
              type: "string",
              description: "When to check back, ISO8601 UTC (e.g. 2026-07-06T15:00:00Z)."
            },
            context: %{
              type: "string",
              description:
                "Optional: one short line quoting the original commitment, for phrasing the " <>
                  "check-back naturally."
            }
          },
          required: ["body", "due_at"]
        }
      },
      %{
        name: "cancel_reminder",
        description:
          "Cancel an upcoming or repeating reminder (\"stop reminding me about the bins\", " <>
            "\"cancel the dentist reminder\"). Ends a repeating series entirely; for a fired " <>
            "one the user is confirming as done, use acknowledge_reminder instead.",
        parameters: %{
          type: "object",
          properties: %{
            reminder: %{
              type: "string",
              description:
                "The short task phrase of the reminder to cancel (e.g. \"take out the bins\")."
            },
            for: %{
              type: "string",
              description:
                "Whose reminder. Omit for the current user. \"household\" for a shared one; a " <>
                  "person's name when they name someone else."
            }
          },
          required: ["reminder"]
        }
      }
    ]
  end

  @impl true
  def execute("create_reminder", _args, %{user_id: nil}),
    do: {:ok, %{note: "no user session — reminder not saved"}}

  def execute("create_reminder", %{"body" => body, "due_at" => due_at} = args, ctx) do
    target =
      Target.resolve(args["for"], %{
        session_user_id: uid(ctx),
        active_scope: Map.get(ctx, :active_scope, :personal),
        gate_on: App.Config.default().kiosk_user_switch,
        users: Enum.filter(Users.list(), &Users.allowed?(&1.email))
      })

    {recurrence, rec_note} = recurrence_arg(args["recurrence"])

    with {:ok, dt, _offset} <- DateTime.from_iso8601(due_at),
         {:ok, r} <-
           Reminders.create(%{
             user_id: target.user_id,
             household: target.household,
             body: body,
             due_at: DateTime.truncate(dt, :second),
             recurrence: recurrence
           }) do
      resp = %{
        body: r.body,
        due_at: DateTime.to_iso8601(r.due_at),
        assigned_to: target.assigned,
        household: r.household
      }

      resp = if r.recurrence, do: Map.put(resp, :recurrence, r.recurrence), else: resp
      resp = if rec_note, do: Map.put(resp, :note, rec_note), else: resp
      {:ok, resp}
    else
      {:error, %Ecto.Changeset{}} -> {:error, :invalid_reminder}
      _ -> {:error, :invalid_due_at}
    end
  end

  def execute("create_reminder", _args, _ctx), do: {:error, :missing_args}

  def execute("list_reminders", _args, %{user_id: nil}), do: {:ok, %{reminders: []}}

  def execute("list_reminders", _args, ctx) do
    items =
      ctx
      |> uid()
      |> Reminders.list_upcoming()
      |> Enum.map(
        &%{
          body: &1.body,
          due_at: DateTime.to_iso8601(&1.due_at),
          kind: &1.kind,
          shared: &1.household
        }
      )

    {:ok, %{reminders: items}}
  end

  def execute("acknowledge_reminder", _args, %{user_id: nil}),
    do: {:ok, %{note: "no user session — nothing to acknowledge"}}

  def execute("acknowledge_reminder", %{"reminder" => phrase}, ctx) do
    uid = uid(ctx)

    case Reminders.find_pending(uid, phrase) do
      nil ->
        # Nothing pending. A recurring series already advanced ("got it" is a friendly no-op on
        # it); an acked one-shot reads as already-cleared; else a benign nothing-to-clear — the
        # brain must never confabulate a lost/failed save.
        cond do
          r = recurring_match(uid, phrase) ->
            {:ok, %{recurring: r.body, note: "that one's on a schedule — it'll come back around"}}

          r = Reminders.find_acknowledged(uid, phrase) ->
            {:ok,
             %{already_done: r.body, note: "that one's already been cleared — no action needed"}}

          true ->
            {:ok, %{note: "no pending reminder by that name — nothing to clear"}}
        end

      r ->
        Reminders.acknowledge(r)
        {:ok, %{acknowledged: r.body}}
    end
  end

  def execute("acknowledge_reminder", _args, _ctx), do: {:error, :missing_args}

  def execute("cancel_reminder", _args, %{user_id: nil}),
    do: {:ok, %{note: "no user session — nothing to cancel"}}

  def execute("cancel_reminder", %{"reminder" => phrase} = args, ctx) do
    target =
      Target.resolve(args["for"], %{
        session_user_id: uid(ctx),
        active_scope: Map.get(ctx, :active_scope, :personal),
        gate_on: App.Config.default().kiosk_user_switch,
        users: Enum.filter(Users.list(), &Users.allowed?(&1.email))
      })

    case Reminders.find_active(target.user_id, phrase) do
      nil ->
        {:ok, %{note: "no active reminder matching that — nothing to cancel"}}

      r ->
        {:ok, _} = Reminders.delete(r)
        {:ok, %{cancelled: r.body, was_recurring: r.recurrence != nil}}
    end
  end

  def execute("cancel_reminder", _args, _ctx), do: {:error, :missing_args}

  def execute("create_followup", _args, %{user_id: nil}),
    do: {:ok, %{note: "no user session — follow-up not saved"}}

  def execute("create_followup", %{"body" => body, "due_at" => due_at} = args, ctx) do
    with {:ok, dt, _offset} <- DateTime.from_iso8601(due_at),
         {:ok, r} <-
           Reminders.create(%{
             user_id: uid(ctx),
             body: body,
             due_at: DateTime.truncate(dt, :second),
             kind: "followup",
             context: args["context"]
           }) do
      {:ok, %{body: r.body, due_at: DateTime.to_iso8601(r.due_at)}}
    else
      {:error, %Ecto.Changeset{}} -> {:error, :invalid_followup}
      _ -> {:error, :invalid_due_at}
    end
  end

  def execute("create_followup", _args, _ctx), do: {:error, :missing_args}

  @doc false
  # Validate + normalize the brain's recurrence arg into the stored rule shape (string keys).
  # {:ok, rule} or :invalid — :invalid degrades the create to a one-shot with a narrated note
  # (never crash a turn on a malformed rule). Policy: freq must be one of the four; interval
  # nil→1, integer-valued number >= 1 kept (JSON numbers may arrive as floats), else invalid;
  # byday only kept for weekly (downcased, filtered to valid codes, deduped; empty → key
  # omitted = due_at's weekday); until must parse as ISO8601 (re-emitted as UTC) — an
  # unparseable end must NOT silently become "forever"; count must be >= 1 (a count of 0 is a
  # nonsense series → one-shot) and seeds remaining.
  def normalize_recurrence(%{"freq" => freq} = raw) when is_binary(freq) do
    freq = freq |> String.trim() |> String.downcase()

    with true <- freq in @valid_freqs,
         {:ok, interval} <- norm_interval(raw["interval"]),
         {:ok, until} <- norm_until(raw["until"]),
         {:ok, count} <- norm_count(raw["count"]) do
      rule =
        %{"freq" => freq, "interval" => interval}
        |> put_byday(freq, raw["byday"])
        |> put_kv("until", until)
        |> put_kv("count", count)
        |> put_kv("remaining", count)

      {:ok, rule}
    else
      _ -> :invalid
    end
  end

  def normalize_recurrence(_), do: :invalid

  # nil → one-shot (no note). A map → normalize; malformed degrades to one-shot + a note the
  # brain narrates. {rule_or_nil, note_or_nil}
  defp recurrence_arg(nil), do: {nil, nil}

  defp recurrence_arg(raw) do
    case normalize_recurrence(raw) do
      {:ok, rule} -> {rule, nil}
      :invalid -> {nil, "couldn't understand the repeat rule — saved as a one-time reminder"}
    end
  end

  defp norm_interval(nil), do: {:ok, 1}
  defp norm_interval(i) when is_integer(i) and i >= 1, do: {:ok, i}

  defp norm_interval(f) when is_float(f) do
    if f >= 1 and f == trunc(f), do: {:ok, trunc(f)}, else: :invalid
  end

  defp norm_interval(_), do: :invalid

  defp norm_until(nil), do: {:ok, nil}

  defp norm_until(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> {:ok, dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()}
      _ -> :invalid
    end
  end

  defp norm_until(_), do: :invalid

  defp norm_count(nil), do: {:ok, nil}
  defp norm_count(c) when is_integer(c) and c >= 1, do: {:ok, c}

  defp norm_count(f) when is_float(f) do
    if f >= 1 and f == trunc(f), do: {:ok, trunc(f)}, else: :invalid
  end

  defp norm_count(_), do: :invalid

  defp put_byday(rule, "weekly", [_ | _] = codes) do
    days =
      codes
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
      |> Enum.filter(&(&1 in @valid_days))
      |> Enum.uniq()

    if days == [], do: rule, else: Map.put(rule, "byday", days)
  end

  defp put_byday(rule, _freq, _byday), do: rule

  defp put_kv(rule, _k, nil), do: rule
  defp put_kv(rule, k, v), do: Map.put(rule, k, v)

  # "Got it" on a recurring reminder is a friendly no-op on the series (it already advanced).
  defp recurring_match(uid, phrase) do
    case Reminders.find_active(uid, phrase) do
      %{recurrence: rec} = r when not is_nil(rec) -> r
      _ -> nil
    end
  end

  defp uid(%{user_id: uid}), do: uid
end
