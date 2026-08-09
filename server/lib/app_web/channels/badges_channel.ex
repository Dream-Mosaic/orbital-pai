defmodule AppWeb.BadgesChannel do
  @moduledoc """
  The nav's badge counts.

  Its own topic, deliberately. The counts have to be right while every panel is
  CLOSED, so they cannot live on a panel's topic — the client would have to join
  all of them just to know whether to draw a dot. And not on `voice:*` either:
  that topic is ESSENTIAL, so a crash or a refusal there escalates to a full
  reconnect, and a badge count must never be able to do that.

  The payload is a map rather than a boolean so the next panel adds a key
  instead of a channel.
  """
  use AppWeb, :channel

  alias App.Reminders

  @impl true
  def join("badges:" <> _ignored, _payload, socket) do
    # The suffix is ignored; the user is whoever the token authenticated.
    uid = socket.assigns.user_id
    Phoenix.PubSub.subscribe(App.PubSub, "reminders:#{uid}")
    Phoenix.PubSub.subscribe(App.PubSub, "reminders:household")
    # Pushed from handle_info, not inline, so join/3 returns fast — same shape
    # as VoiceChannel's :after_join.
    send(self(), :push_badges)
    {:ok, socket}
  end

  @impl true
  def handle_info(:push_badges, socket), do: {:noreply, push_badges(socket)}
  def handle_info({:reminders_changed}, socket), do: {:noreply, push_badges(socket)}
  def handle_info({:reminder_due, _reminder}, socket), do: {:noreply, push_badges(socket)}

  defp push_badges(socket) do
    uid = socket.assigns.user_id
    push(socket, "badges", %{reminders: length(Reminders.list_unacknowledged(uid))})
    socket
  end
end
