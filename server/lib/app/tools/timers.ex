defmodule App.Tools.Timers do
  @moduledoc """
  The timers tool: `set_timer` (a countdown of `duration_seconds`, optionally labelled),
  `list_timers` (what's running and how long is left), `cancel_timer` (by label, `all`, or —
  with neither — the obvious one). Persistence and ringing live in `App.Timers`; this module
  only translates between the brain's arguments and human-friendly results ("9 min 41 s",
  "6:42 PM" in the instance timezone).
  """
  @behaviour App.Tools.Tool

  alias App.Timers
  alias App.Timers.Timer

  @range_error "duration_seconds must be a whole number of seconds from 1 to 86400 " <>
                 "(a timer runs at most 24 hours) — convert what the user said, " <>
                 "e.g. 10 minutes = 600."

  @impl true
  def declarations do
    [
      %{
        name: "set_timer",
        description:
          "Start a countdown timer (a kitchen timer). It rings with an alarm on every one of " <>
            "the user's devices when it ends. Several can run at once.",
        parameters: %{
          type: "object",
          properties: %{
            duration_seconds: %{
              type: "integer",
              description:
                "How long, in seconds (10 minutes = 600, 1 hour 30 minutes = 5400). 1 to 86400."
            },
            label: %{
              type: "string",
              description:
                "Optional short name when the user gives one (\"pasta\", \"eggs\", \"laundry\") " <>
                  "— just the name, without the word \"timer\". Omit for an unnamed timer."
            }
          },
          required: ["duration_seconds"]
        }
      },
      %{
        name: "list_timers",
        description:
          "The user's running (and ringing) timers with time remaining — for \"how long left " <>
            "on the pasta?\" or \"what timers do I have?\".",
        parameters: %{type: "object", properties: %{}}
      },
      %{
        name: "add_to_timer",
        description:
          "Add time to a timer: \"add 2 minutes to the pasta\", or, while one is ringing, " <>
            "\"give it 5 more minutes\" (it starts counting again). Label picks one; omit it " <>
            "for the ringing timer or the only one.",
        parameters: %{
          type: "object",
          properties: %{
            seconds: %{
              type: "integer",
              description: "How much to add, in seconds (2 minutes = 120)."
            },
            label: %{
              type: "string",
              description: "The timer's name (\"pasta\"), if they gave one."
            }
          },
          required: ["seconds"]
        }
      },
      %{
        name: "cancel_timer",
        description:
          "Cancel a running timer, or silence one that is ringing. Pass the label to pick one, " <>
            "all=true for every timer, or neither when there is only one (or one is ringing).",
        parameters: %{
          type: "object",
          properties: %{
            label: %{type: "string", description: "The timer's name (\"pasta\")."},
            all: %{type: "boolean", description: "true to cancel every timer."}
          }
        }
      }
    ]
  end

  @impl true
  def prompt do
    "Timers: a COUNTDOWN (\"set a timer for 10 minutes\", \"pasta timer, 8 minutes\", " <>
      "\"start a 30-second timer\") is set_timer with duration_seconds, plus a short label when " <>
      "they name one — never a reminder. A reminder is for a task at a clock time or something " <>
      "to DO later (\"remind me at 5 to call mom\", \"remind me in 20 minutes to move the " <>
      "laundry\"). Timers ring with an alarm on all of the user's devices and show a live " <>
      "countdown, so confirm in a few words (\"Pasta timer, 10 minutes.\") without reading " <>
      "back the end time unless asked. \"How long left?\" is list_timers. \"Cancel\" or " <>
      "\"stop\" the timer is cancel_timer — it also silences a ringing one; pass the label when " <>
      "they name one, all=true for all of them, and neither when there's just one. \"Add 2 " <>
      "minutes to the pasta\" or, while it rings, \"give it 5 more minutes\" is add_to_timer."
  end

  @impl true
  def bridge(_name), do: []

  @impl true
  def execute(_name, _args, %{user_id: nil}),
    do: {:ok, %{note: "no user session — timer not set or changed"}}

  def execute("set_timer", args, ctx) do
    with {:ok, seconds} <- seconds_arg(args["duration_seconds"]),
         {:ok, %Timer{} = t} <- Timers.create(ctx.user_id, seconds, args["label"]) do
      {:ok,
       %{
         set: true,
         label: t.label,
         duration: human_ms(t.duration_ms),
         ends_at_local: local_clock(t.ends_at),
         active_timers: length(Timers.list_active(ctx.user_id))
       }}
    else
      {:error, :invalid_duration} -> {:error, @range_error}
      {:error, _changeset} -> {:error, "couldn't save that timer"}
    end
  end

  def execute("add_to_timer", args, ctx) do
    with {:ok, seconds} <- seconds_arg(args["seconds"]),
         {:ok, %Timer{} = t} <- Timers.extend(ctx.user_id, args["label"], seconds) do
      {:ok,
       %{
         extended: true,
         label: t.label,
         added: human_ms(seconds * 1000),
         remaining: human_ms(Timers.remaining_ms(t, DateTime.utc_now())),
         ends_at_local: local_clock(t.ends_at)
       }}
    else
      {:error, :invalid_duration} ->
        {:error, @range_error}

      {:error, :not_found} ->
        {:ok, %{extended: false, note: "no timer by that name is running"}}

      {:error, {:ambiguous, many}} ->
        {:ok,
         %{
           extended: false,
           note: "which timer?",
           timers: Enum.map(many, &(&1.label || "unnamed"))
         }}
    end
  end

  def execute("list_timers", _args, ctx) do
    now = DateTime.utc_now()
    timers = Enum.map(Timers.list_active(ctx.user_id), &describe(&1, now))
    result = %{count: length(timers), timers: timers}
    {:ok, if(timers == [], do: Map.put(result, :note, "no timers running"), else: result)}
  end

  def execute("cancel_timer", args, ctx) do
    uid = ctx.user_id

    cond do
      args["all"] == true ->
        uid |> Timers.cancel(:all) |> cancel_result(uid, nil)

      label?(args["label"]) ->
        uid |> Timers.cancel(args["label"]) |> cancel_result(uid, args["label"])

      true ->
        cancel_obvious(uid)
    end
  end

  def execute(_name, _args, _ctx), do: {:error, :unknown_function}

  # No label, no `all`: the one ringing timer (that's what "stop!" means while it rings), else
  # the only timer, else ask which.
  defp cancel_obvious(uid) do
    active = Timers.list_active(uid)

    case {Enum.filter(active, &(&1.state == "ringing")), active} do
      {_, []} -> cancel_result({:error, :not_found}, uid, nil)
      {[ringing], _} -> uid |> Timers.cancel(ringing.id) |> cancel_result(uid, nil)
      {_, [only]} -> uid |> Timers.cancel(only.id) |> cancel_result(uid, nil)
      {_, many} -> cancel_result({:error, {:ambiguous, many}}, uid, nil)
    end
  end

  defp cancel_result({:ok, stopped}, _uid, _label) do
    now = DateTime.utc_now()
    {:ok, %{cancelled: Enum.map(stopped, &describe(&1, now))}}
  end

  defp cancel_result({:error, :not_found}, _uid, nil),
    do: {:ok, %{note: "no timers running — nothing to cancel"}}

  # Nothing by that name: say so, and list what IS running so the brain can offer it.
  defp cancel_result({:error, :not_found}, uid, label) do
    now = DateTime.utc_now()

    {:ok,
     %{
       note: "no timer called \"#{label}\" — nothing cancelled",
       timers: Enum.map(Timers.list_active(uid), &describe(&1, now))
     }}
  end

  defp cancel_result({:error, {:ambiguous, matches}}, _uid, _label) do
    now = DateTime.utc_now()

    {:ok,
     %{
       ambiguous: true,
       note: "more than one timer could be meant — ask the user which one (or all)",
       timers: Enum.map(matches, &describe(&1, now))
     }}
  end

  defp describe(%Timer{} = t, now) do
    %{
      label: t.label,
      state: t.state,
      duration: human_ms(t.duration_ms),
      remaining: human_ms(Timers.remaining_ms(t, now)),
      ends_at_local: local_clock(t.ends_at)
    }
  end

  defp label?(label), do: is_binary(label) and String.trim(label) != ""

  defp seconds_arg(n) when is_integer(n), do: {:ok, n}
  defp seconds_arg(n) when is_float(n), do: {:ok, round(n)}
  defp seconds_arg(_), do: {:error, :invalid_duration}

  @doc false
  # "10 min", "9 min 41 s", "45 s", "1 h 30 min". Rounds UP to the next whole second (and, past
  # an hour, the next minute): a countdown that says "0 s" while still running reads as broken.
  def human_ms(ms) when ms <= 0, do: "0 s"

  def human_ms(ms) do
    s = div(ms + 999, 1000)

    if s >= 3600 do
      m = div(s + 59, 60)
      join([{div(m, 60), "h"}, {rem(m, 60), "min"}])
    else
      join([{div(s, 60), "min"}, {rem(s, 60), "s"}])
    end
  end

  defp join(parts) do
    parts
    |> Enum.reject(fn {n, _} -> n == 0 end)
    |> Enum.map_join(" ", fn {n, unit} -> "#{n} #{unit}" end)
  end

  @doc false
  # The end time on the user's wall clock ("6:42 PM"), "tomorrow …" when it crosses midnight.
  def local_clock(%DateTime{} = at) do
    tz = App.Config.timezone()
    local = DateTime.shift_zone!(at, tz)
    today = DateTime.utc_now() |> DateTime.shift_zone!(tz) |> DateTime.to_date()
    clock = Calendar.strftime(local, "%-I:%M %p")
    if Date.compare(DateTime.to_date(local), today) == :gt, do: "tomorrow " <> clock, else: clock
  end
end
