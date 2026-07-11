defmodule App.Reminders do
  @moduledoc """
  Local reminders: create, list, find-due, and acknowledge. Times are stored UTC. Persistence
  + queries, plus a thin notify seam: create/acknowledge/delete broadcast `{:reminders_changed}`
  on `"reminders:<user_id>"` so the LiveView panel stays live (same pattern as `App.Memory`).
  Household (shared) rows also notify `"reminders:household"` so every member's panel updates.
  The `App.Reminders.Scheduler` drives firing (and broadcasts `{:reminder_due, r}`).
  """
  import Ecto.Query
  alias App.Repo
  alias App.Reminders.Reminder

  def create(attrs) do
    case %Reminder{} |> Reminder.changeset(attrs) |> Repo.insert() do
      {:ok, r} ->
        broadcast_changed(r.user_id, r.household)
        {:ok, r}

      other ->
        other
    end
  end

  def delete(%Reminder{} = r) do
    case Repo.delete(r) do
      {:ok, deleted} ->
        broadcast_changed(deleted.user_id, deleted.household)
        {:ok, deleted}

      other ->
        other
    end
  end

  @doc "Mark a fired reminder as spoken/acknowledged. No-op on an un-persisted struct."
  def acknowledge(%Reminder{id: nil}), do: :ok

  def acknowledge(%Reminder{} = r) do
    case r |> Reminder.changeset(%{acknowledged_at: now()}) |> Repo.update() do
      {:ok, updated} ->
        broadcast_changed(updated.user_id, updated.household)
        {:ok, updated}

      other ->
        other
    end
  end

  @doc "Stamp a reminder as spoken by Henry (delivered) — it stays PENDING until the human acks."
  def mark_delivered(%Reminder{id: nil}), do: :ok

  def mark_delivered(%Reminder{} = r) do
    case r |> Reminder.changeset(%{delivered_at: now()}) |> Repo.update() do
      {:ok, updated} ->
        broadcast_changed(updated.user_id, updated.household)
        {:ok, updated}

      other ->
        other
    end
  end

  def list_upcoming(user_id) do
    now = now()

    Reminder
    |> where(
      [r],
      (r.user_id == ^user_id or r.household == true) and is_nil(r.fired_at) and r.due_at >= ^now
    )
    |> order_by([r], asc: r.due_at, asc: r.id)
    |> Repo.all()
  end

  @doc "Fired but not yet spoken/acknowledged — the panel's 'needs your attention' list."
  def list_unacknowledged(user_id) do
    Reminder
    |> where(
      [r],
      (r.user_id == ^user_id or r.household == true) and not is_nil(r.fired_at) and
        is_nil(r.acknowledged_at)
    )
    |> order_by([r], desc: r.fired_at, desc: r.id)
    |> Repo.all()
  end

  @doc """
  The user's best-matching PENDING (fired, un-acked) reminder for a spoken phrase — own OR household.
  Matches case-insensitively when the phrase is contained in the body or vice versa; most recently
  fired wins ties. nil when nothing matches (so the brain can say it couldn't find it).
  """
  def find_pending(user_id, phrase) when is_binary(phrase) do
    p = phrase |> String.downcase() |> String.trim()

    if p == "" do
      nil
    else
      user_id
      |> list_unacknowledged()
      |> Enum.filter(fn r ->
        b = String.downcase(r.body)
        String.contains?(b, p) or String.contains?(p, b)
      end)
      |> Enum.sort_by(& &1.fired_at, {:desc, DateTime})
      |> List.first()
    end
  end

  def find_pending(_user_id, _phrase), do: nil

  @doc """
  The user's best-matching ALREADY-ACKNOWLEDGED reminder for a phrase — own OR household. Same
  matching as `find_pending/2`, but over fired + acknowledged rows, so the ack tool can tell
  "already cleared" apart from "never existed" (else the brain confabulates a lost reminder when it
  finds nothing pending). Most recently acknowledged wins; nil when nothing matches.
  """
  def find_acknowledged(user_id, phrase) when is_binary(phrase) do
    p = phrase |> String.downcase() |> String.trim()

    if p == "" do
      nil
    else
      Reminder
      |> where(
        [r],
        (r.user_id == ^user_id or r.household == true) and not is_nil(r.fired_at) and
          not is_nil(r.acknowledged_at)
      )
      |> Repo.all()
      |> Enum.filter(fn r ->
        b = String.downcase(r.body)
        String.contains?(b, p) or String.contains?(p, b)
      end)
      |> Enum.sort_by(& &1.acknowledged_at, {:desc, DateTime})
      |> List.first()
    end
  end

  def find_acknowledged(_user_id, _phrase), do: nil

  @doc "Upcoming household (shared) reminders only — backs the Shared-scope view."
  def list_household_upcoming do
    now = now()

    Reminder
    |> where([r], r.household == true and is_nil(r.fired_at) and r.due_at >= ^now)
    |> order_by([r], asc: r.due_at, asc: r.id)
    |> Repo.all()
  end

  @doc "Unfired reminders whose time has come (across all users — the scheduler routes by user)."
  def due_now(at \\ nil) do
    cutoff = at || now()

    Reminder
    |> where([r], is_nil(r.fired_at) and r.due_at <= ^cutoff)
    |> Repo.all()
  end

  def mark_fired(%Reminder{} = r) do
    r |> Reminder.changeset(%{fired_at: now()}) |> Repo.update()
  end

  @doc "Tell subscribers the reminder set changed. Household rows also notify every member's panel."
  def broadcast_changed(user_id) do
    Phoenix.PubSub.broadcast(App.PubSub, "reminders:#{user_id}", {:reminders_changed})
  end

  def broadcast_changed(user_id, true) do
    broadcast_changed(user_id)
    Phoenix.PubSub.broadcast(App.PubSub, "reminders:household", {:reminders_changed})
  end

  def broadcast_changed(user_id, false), do: broadcast_changed(user_id)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
