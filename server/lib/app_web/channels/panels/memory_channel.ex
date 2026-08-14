defmodule AppWeb.Panels.MemoryChannel do
  @moduledoc """
  The native Memory drawer's data path. Joined only while the Memory LAYER is
  visible inside the Settings drawer.

  Non-essential: a refusal stops this channel and leaves the conversation alone.

  This channel RIDES THE BROADCAST. `App.Memory` calls `broadcast_updated/0`
  from create_fact/1, delete_fact/1, put_summary/2 and forget/1, so the write
  handlers here mutate and let the re-push come back around — the same shape as
  `AppWeb.Panels.RemindersChannel`, and the OPPOSITE of
  `AppWeb.Panels.SettingsChannel`, which pushes from its handlers because
  `Users.update_prefs/2` does not broadcast. Do not unify the two without
  checking which context broadcasts.

  Known and accepted: `Memory.subscribe/0` subscribes to ONE GLOBAL topic, not a
  per-user one, so any user's memory change wakes every subscriber and each
  re-queries its own user's rows. Correctly scoped, merely wasteful; fixing it
  means adding a per-user topic to `App.Memory`, which the LiveView also uses.
  """
  use AppWeb, :channel

  alias App.Memory

  @impl true
  def join("panel:memory:" <> _ignored, _payload, socket) do
    Memory.subscribe()
    send(self(), :push_state)
    {:ok, socket}
  end

  @impl true
  def handle_info(:push_state, socket), do: {:noreply, push_state(socket)}
  def handle_info(:memory_updated, socket), do: {:noreply, push_state(socket)}

  defp push_state(socket) do
    uid = socket.assigns.user_id

    push(socket, "state", %{
      summary: Memory.get_summary(uid).content,
      facts: Enum.map(Memory.list_facts(uid), &fact/1)
    })

    socket
  end

  defp fact(f), do: %{id: f.id, content: f.content, source: f.source}
end
