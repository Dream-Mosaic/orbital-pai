defmodule App.Sources.Calendar do
  @moduledoc """
  Calendar as a semantic source. `list_refs` reads the primary calendar over a [past, future]
  window (normalized events) and derives a `content_hash` over the event's mutable fields, so a
  reschedule/edit re-embeds. `to_point` is a pure transform of the already-fetched event — no
  second API call. Reconcile is `:full` (vanished events are pruned each successful tick).
  """
  @behaviour App.Sources

  alias App.Google.Calendar

  @impl true
  def source_key, do: "calendar"

  @impl true
  def connector, do: :calendar

  @impl true
  def reconcile_mode, do: :full

  @impl true
  def list_refs(account) do
    cfg = App.Config.default()
    now = DateTime.utc_now()

    time_min =
      now
      |> DateTime.add(-cfg.calendar_index_past_days * 86_400, :second)
      |> DateTime.to_iso8601()

    time_max =
      now
      |> DateTime.add(cfg.calendar_index_future_days * 86_400, :second)
      |> DateTime.to_iso8601()

    with {:ok, events} <-
           Calendar.list_events(account,
             time_min: time_min,
             time_max: time_max,
             max_results: 2500
           ) do
      {:ok, Enum.flat_map(events, &to_ref/1)}
    end
  end

  @impl true
  def to_point(account, %{raw: ev}) do
    {:ok,
     %{
       embed_text: embed_text(ev),
       at: start_datetime(ev),
       payload: %{
         user_id: account.user_id,
         source: "calendar",
         external_id: ev.id,
         account_id: account.id,
         account: account.label,
         at: to_string(ev.start),
         link: ev.html_link,
         title: ev.summary,
         when_human: when_human(ev),
         location: ev.location
       }
     }}
  end

  # events without an id can't be tracked/deduped — skip them.
  defp to_ref(%{id: nil}), do: []
  defp to_ref(ev), do: [%{external_id: ev.id, content_hash: hash(ev), raw: ev}]

  defp embed_text(ev) do
    """
    #{ev.summary}
    When: #{when_human(ev)}
    Where: #{ev.location}
    #{String.slice(ev.description || "", 0, 8_000)}
    With: #{Enum.join(ev.attendees, ", ")}
    """
    |> String.trim()
  end

  defp hash(ev) do
    parts = [
      ev.summary,
      ev.start,
      ev.end,
      ev.location,
      ev.description,
      Enum.join(ev.attendees, ",")
    ]

    :sha
    |> :crypto.hash(Enum.map_join(parts, "|", &to_string/1))
    |> Base.encode16(case: :lower)
  end

  defp when_human(%{all_day?: true, start: s}), do: to_string(s)

  defp when_human(%{start: s}) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> Calendar.format_when(dt)
      _ -> s
    end
  end

  defp when_human(%{start: s}), do: to_string(s)

  defp start_datetime(%{all_day?: true, start: d}) when is_binary(d) do
    case Date.from_iso8601(d) do
      {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
      _ -> nil
    end
  end

  defp start_datetime(%{start: s}) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp start_datetime(_), do: nil
end
