defmodule App.Tools.Reminders do
  @moduledoc """
  The reminders tool: functions the brain can call. `create_reminder` takes an ISO8601
  UTC `due_at` (the model resolves relative times from the 'Current time' line in its
  prompt — we do no NL date parsing). `list_reminders` reads upcoming ones (each tagged with
  `kind`). `create_followup` is the same shape as `create_reminder` but marks `kind: "followup"`
  with an optional `context` line — an open loop the brain offered to check back on.
  """
  @behaviour App.Tools.Tool

  alias App.Reminders
  alias App.Reminders.Target
  alias App.Users

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

    with {:ok, dt, _offset} <- DateTime.from_iso8601(due_at),
         {:ok, r} <-
           Reminders.create(%{
             user_id: target.user_id,
             household: target.household,
             body: body,
             due_at: DateTime.truncate(dt, :second)
           }) do
      {:ok,
       %{
         body: r.body,
         due_at: DateTime.to_iso8601(r.due_at),
         assigned_to: target.assigned,
         household: r.household
       }}
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

  defp uid(%{user_id: uid}), do: uid
end
