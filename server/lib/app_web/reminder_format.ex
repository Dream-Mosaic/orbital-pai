defmodule AppWeb.ReminderFormat do
  @moduledoc """
  Display strings for a reminder: the due timestamp and the recurrence cadence,
  both in `App.Config.default().timezone`.

  Lives outside `AppWeb.VoiceModals` because it has two consumers now — the
  LiveView's panel component and `AppWeb.Panels.RemindersChannel`, which renders
  these server-side so the native client never reimplements timezone-dependent
  humanising in Dart.
  """

  # due_at is stored UTC; shift to the configured local timezone for display.
  @doc false
  def fmt_due(%DateTime{} = dt) do
    local = DateTime.shift_zone!(dt, App.Config.default().timezone)
    Calendar.strftime(local, "%b %-d %-I:%M%P")
  end

  # Humanize a recurrence rule for the cadence badge: "every Tue", "every 3 days",
  # "monthly on the 1st", "yearly". Day-of-month/weekday fall back to due_at, rendered in the
  # configured local timezone (same as fmt_due/1). nil rule (one-shot) → nil (no badge).
  @doc false
  def fmt_recurrence(nil, _due_at), do: nil

  def fmt_recurrence(%{"freq" => freq} = rule, %DateTime{} = due_at) do
    interval = rule["interval"] || 1
    local = DateTime.shift_zone!(due_at, App.Config.default().timezone)

    case freq do
      "daily" ->
        if interval == 1, do: "daily", else: "every #{interval} days"

      "weekly" ->
        days = byday_label(rule, local)
        if interval == 1, do: "every #{days}", else: "every #{interval} wks: #{days}"

      "monthly" ->
        day = "the #{ordinal(local.day)}"
        if interval == 1, do: "monthly on #{day}", else: "every #{interval} months on #{day}"

      "yearly" ->
        if interval == 1, do: "yearly", else: "every #{interval} years"

      _ ->
        "repeats"
    end
  end

  def fmt_recurrence(_rule, _due_at), do: "repeats"

  defp byday_label(%{"byday" => [_ | _] = codes}, _local),
    do: codes |> Enum.map(&String.capitalize/1) |> Enum.join(", ")

  defp byday_label(_rule, local), do: Calendar.strftime(local, "%a")

  defp ordinal(n) when n in [1, 21, 31], do: "#{n}st"
  defp ordinal(n) when n in [2, 22], do: "#{n}nd"
  defp ordinal(n) when n in [3, 23], do: "#{n}rd"
  defp ordinal(n), do: "#{n}th"
end
