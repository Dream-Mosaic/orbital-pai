defmodule AppWeb.BookFormat do
  @moduledoc """
  Display strings and orderings for the Books panel: item order, a plant's meta
  line, a note's date, season order, and the type-aware Clear confirmation.

  Lives outside `AppWeb.VoiceModals` for the same reason `AppWeb.ReminderFormat`
  does — there are two consumers now: the LiveView's `books_panel/1` and
  `AppWeb.Panels.BooksChannel`, which renders these server-side so the native
  client never grows a second, drifting copy of the same copy.
  """

  @doc """
  Unchecked first. `Enum.sort_by/2` is STABLE, so within each group the preload
  order (`inserted_at`, then `id` — `App.Lists.items_query/0`) is preserved.
  """
  def sorted_items(list), do: Enum.sort_by(list.items, &(&1.checked_at != nil))

  @doc "How many of `list`'s items are checked off — gates the Clear done control."
  def done_count(list), do: Enum.count(list.items, &(&1.checked_at != nil))

  @doc ~S|"Roma · back bed · 5 plants · planted Jul 11" — only the fields that exist.|
  def plant_meta(plant) do
    [
      plant.species,
      plant.location,
      plant.count && "#{plant.count} plants",
      plant.planted_on && "planted #{Calendar.strftime(plant.planted_on, "%b %-d")}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  @doc """
  The summary line of a plant's notes disclosure. Notes come preloaded
  oldest-first (`Garden.garden/1`), so the latest is the LAST.
  """
  def latest_note_line(plant) do
    case List.last(plant.notes) do
      nil -> "Notes"
      note -> note.body
    end
  end

  @doc "A note's date badge: `noted_on` when it has one, else the day it was written."
  def fmt_noted(%{noted_on: %Date{} = d}), do: Calendar.strftime(d, "%b %-d")
  def fmt_noted(%{inserted_at: dt}), do: Calendar.strftime(dt, "%b %-d")

  @doc """
  Most recent season first ("Summer 2026" and "2026" sort fine as strings within
  a year; exact cross-format ordering is cosmetic). Returns a LIST of
  `{season, plants}` — the channel keeps it a list on the wire because JSON
  object key order does not survive the round trip.
  """
  def seasons_desc(by_season), do: Enum.sort_by(by_season, fn {season, _} -> season end, :desc)

  @doc "The type-aware Clear confirmation: closing a season reads nothing like emptying a list."
  def clear_confirm(%{kind: :garden}),
    do: "Close out this season? Active plants move to Past seasons — nothing is deleted."

  def clear_confirm(%{label: label}),
    do: "Clear everything off #{label}? The list stays, just empty."
end
