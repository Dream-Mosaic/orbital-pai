defmodule AppWeb.Panels.RemindersChannel do
  @moduledoc """
  The native Reminders drawer's data path.

  Joined only while the drawer is on screen — join MEANS open and leave MEANS
  close, so there is no open/close protocol to keep in sync and the server does
  no work for a panel nobody is looking at.

  Non-essential (spec §5.1): a refusal here stops this channel and leaves the
  conversation and its socket alone.

  Display strings are rendered here rather than in Dart. `due_label` and
  `recurrence_label` both depend on `App.Config.default().timezone`, and
  reimplementing timezone-dependent humanising client-side would be two
  divergent implementations of the same copy.
  """
  use AppWeb, :channel

  alias App.Reminders
  alias AppWeb.ReminderFormat

  @impl true
  def join("panel:reminders:" <> _ignored, _payload, socket) do
    # The suffix is ignored; the user is whoever the token authenticated.
    uid = socket.assigns.user_id
    Phoenix.PubSub.subscribe(App.PubSub, "reminders:#{uid}")
    Phoenix.PubSub.subscribe(App.PubSub, "reminders:household")
    send(self(), :push_state)
    {:ok, socket}
  end

  @impl true
  def handle_info(:push_state, socket), do: {:noreply, push_state(socket)}
  def handle_info({:reminders_changed}, socket), do: {:noreply, push_state(socket)}
  def handle_info({:reminder_due, _reminder}, socket), do: {:noreply, push_state(socket)}

  defp push_state(socket) do
    uid = socket.assigns.user_id

    push(socket, "state", %{
      due: Enum.map(Reminders.list_unacknowledged(uid), &row/1),
      upcoming: Enum.map(Reminders.list_upcoming(uid), &row/1)
    })

    socket
  end

  defp row(r) do
    %{
      id: r.id,
      body: r.body,
      due_label: ReminderFormat.fmt_due(r.due_at),
      recurrence_label: ReminderFormat.fmt_recurrence(r.recurrence, r.due_at),
      household: r.household,
      kind: r.kind
    }
  end
end
