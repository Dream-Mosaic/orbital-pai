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

  # ---- inbound: client -> server ----
  #
  # Neither handler pushes `state`. acknowledge/1 and delete/1 already
  # broadcast_changed/2, and PubSub delivers a broadcast to its sender, so the
  # subscription above does the re-push. One path for "the set changed",
  # whoever changed it — this panel, the web LiveView, a voice ack, or the
  # scheduler firing.
  #
  # The id comes from the client, so it is resolved against the user's OWN
  # lists — never Repo.get/2. Both list queries already include household rows,
  # so the rule is "anything the user can see", not "anything the user owns".
  @impl true
  def handle_in("ack", %{"id" => id}, socket) when is_integer(id) do
    # The due list only: acknowledging something that never fired is meaningless.
    case Enum.find(Reminders.list_unacknowledged(socket.assigns.user_id), &(&1.id == id)) do
      nil ->
        {:reply, {:error, %{reason: "not_found"}}, socket}

      reminder ->
        Reminders.acknowledge(reminder)
        {:reply, :ok, socket}
    end
  end

  def handle_in("dismiss", %{"id" => id}, socket) when is_integer(id) do
    uid = socket.assigns.user_id
    visible = Reminders.list_unacknowledged(uid) ++ Reminders.list_upcoming(uid)

    case Enum.find(visible, &(&1.id == id)) do
      nil ->
        {:reply, {:error, %{reason: "not_found"}}, socket}

      reminder ->
        # On a recurring row this cancels the whole series — the row IS the
        # series, same as the web's ✕.
        Reminders.delete(reminder)
        {:reply, :ok, socket}
    end
  end

  # A client bug must not crash the channel and drop the panel.
  def handle_in(event, _payload, socket) when event in ~w(ack dismiss),
    do: {:reply, {:error, %{reason: "bad_request"}}, socket}

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
