defmodule AppWeb.Panels.MemoryChannel do
  @moduledoc """
  The native Memory drawer's data path. Joined only while the Memory LAYER is
  visible inside the Settings drawer.

  Non-essential: a refusal stops this channel and leaves the conversation alone.

  This channel RIDES THE BROADCAST: it subscribes in `join/2` and re-pushes
  `state` on every `:memory_updated`, so a change from ANY source reaches an
  open panel with no refresh — the web LiveView editing the same facts, or
  `Memory.Updater` after a turn in which the brain learned something. That
  subscription is the whole reason a fact Henry just picked up appears while
  you are looking at the panel.

  `App.Memory` broadcasts **per logical operation, not per write**, and the
  split is easy to get wrong:

    * `reset/1`, `clear_turns/1`, `forget/1` and `replace_auto_facts/2` call
      `broadcast_updated/0` themselves.
    * `create_fact/1`, `delete_fact/1` and `put_summary/2` do NOT — the caller
      broadcasts once its unit of work is finished. `Memory.Updater.run/1`
      writes a summary and several facts, then broadcasts a single time.

  So the write handlers here call `Memory.broadcast_updated/0` after a
  successful `put_summary`/`create_fact`/`delete_fact`, and deliberately do
  NOT after `forget/1`, which already broadcasts and would push twice. Read
  `memory.ex` before adding or removing one of those calls.

  Contrast `AppWeb.Panels.SettingsChannel`, which pushes `state` from its own
  handlers because `Users.update_prefs/2` has no broadcast at all. Do not
  unify the two without checking what the context underneath actually does.

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

  # ---- inbound ----
  #
  # No handler calls push_state. Each broadcasts instead, and the subscription
  # in join/2 re-pushes to us AND to any open LiveView. put_summary/2 and
  # create_fact/1 do NOT broadcast on their own — the caller does it once its
  # unit of work is done (see the moduledoc). This is the opposite of
  # SettingsChannel, deliberately.
  @impl true
  def handle_in("save_summary", %{"summary" => summary}, socket)
      when is_binary(summary) do
    Memory.put_summary(socket.assigns.user_id, summary)
    Memory.broadcast_updated()
    {:reply, :ok, socket}
  end

  def handle_in("add_fact", %{"content" => content}, socket) when is_binary(content) do
    case String.trim(content) do
      "" ->
        {:reply, {:error, %{reason: "bad_request"}}, socket}

      trimmed ->
        Memory.create_fact(%{
          content: trimmed,
          source: "user",
          user_id: socket.assigns.user_id
        })

        Memory.broadcast_updated()
        {:reply, :ok, socket}
    end
  end

  # A client bug must not crash the channel and drop the panel.
  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{reason: "bad_request"}}, socket}

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
