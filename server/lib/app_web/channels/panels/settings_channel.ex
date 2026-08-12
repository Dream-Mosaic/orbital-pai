defmodule AppWeb.Panels.SettingsChannel do
  @moduledoc """
  The native Settings drawer's data path. Joined only while the drawer is open.

  Non-essential (B1 spec §5.1): a refusal here stops this channel and leaves the
  conversation and its socket alone.

  UNLIKE `AppWeb.Panels.RemindersChannel`, the write handlers push `state`
  themselves. `App.Users.update_prefs/2` does not broadcast, so there is no
  PubSub message to ride — do not "fix" this into a subscription without adding
  a broadcast first. The cost is that a pref changed on the web while this
  drawer is open is not seen until the drawer is reopened, which is acceptable
  for two surfaces one person uses at a time.
  """
  use AppWeb, :channel

  alias App.Conversations.{Conversation, Sessions}
  alias App.Users

  @impl true
  def join("panel:settings:" <> _ignored, _payload, socket) do
    # The suffix is ignored; the user is whoever the token authenticated.
    send(self(), :push_state)
    {:ok, socket}
  end

  # The ONLY prefs a client may set. A literal list, not `String.to_existing_atom/1`:
  # "email", "id" and "books_last_book" are all existing atoms, and
  # `User.prefs_changeset/2` casts books_last_book, voice_lock_mode and
  # voice_lock_threshold — so an atom-existence check would be no guard at all.
  @settable %{
    "default_abi" => :default_abi,
    "default_ptt" => :default_ptt,
    "voice_activation" => :voice_activation
  }

  @impl true
  def handle_in("set_pref", %{"pref" => pref, "value" => value}, socket)
      when is_binary(pref) and is_boolean(value) do
    case Map.fetch(@settable, pref) do
      {:ok, key} -> reply_write(write(socket, %{key => value}))
      :error -> {:reply, {:error, %{reason: "bad_request"}}, socket}
    end
  end

  def handle_in("set_briefing", %{"time" => nil}, socket),
    do: reply_write(write(socket, %{briefing_time: nil}))

  def handle_in("set_briefing", %{"time" => time}, socket) when is_binary(time) do
    if time =~ ~r/^([01]\d|2[0-3]):[0-5]\d$/ do
      reply_write(write(socket, %{briefing_time: time}))
    else
      {:reply, {:error, %{reason: "bad_request"}}, socket}
    end
  end

  def handle_in("set_relock", %{"seconds" => seconds}, socket) when is_integer(seconds) do
    clamped = seconds |> max(10) |> min(30)

    case write(socket, %{relock_seconds: clamped}) do
      {:ok, _socket} = result ->
        # Relock is both a stored default AND a value the running FSM holds, so
        # the write has to reach both. The web relays this through the browser
        # (push_event -> JS hook -> voice channel); server-side it is one call.
        # set_relock_ms/2 takes MILLISECONDS.
        case Sessions.lookup(to_string(socket.assigns.user_id)) do
          {:ok, pid} -> Conversation.set_relock_ms(pid, clamped * 1000)
          :error -> :ok
        end

        reply_write(result)

      error ->
        reply_write(error)
    end
  end

  # Danger zone: the DB is only half of it — the running FSM is still holding
  # turn state the DB no longer has (brain_buffer, pending_request, etc. — see
  # Conversation.reset_turn_fields/1), so a live conversation needs its own
  # reset alongside the delete. Mirrors conversation_live.ex's
  # clear_conversation/forget_me handlers. Neither pushes `state` — no pref
  # changed.
  def handle_in("clear_turns", _payload, socket) do
    App.Memory.clear_turns(socket.assigns.user_id)
    clear_live_fsm(socket)
    {:reply, :ok, socket}
  end

  def handle_in("forget_me", _payload, socket) do
    App.Memory.forget(socket.assigns.user_id)
    clear_live_fsm(socket)
    {:reply, :ok, socket}
  end

  # A client bug must not crash the channel and drop the panel.
  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{reason: "bad_request"}}, socket}

  @impl true
  def handle_info(:push_state, socket), do: {:noreply, push_state(socket)}

  defp reply_write({:ok, socket}), do: {:reply, :ok, socket}

  # Unreachable with today's @settable: is_boolean(value) plus the set_briefing
  # regex (a strict subset of the schema's own HH:MM validate_format) mean every
  # attrs map that reaches write/2 casts cleanly, so update_prefs/2 never fails
  # here. Kept so the NEXT @settable addition (e.g. voice_lock_threshold, which
  # prefs_changeset/2 validates as a cosine in (-1, 1)) can't silently reply :ok
  # and push stale state on a write the changeset actually rejected.
  defp reply_write({:error, socket}), do: {:reply, {:error, %{reason: "bad_request"}}, socket}

  # Persist, then push the fresh state — but only on a successful write. See the
  # moduledoc for why the handler pushes rather than riding a broadcast.
  #
  # Users.get/1 can return nil (no user-deletion path exists today, so this is
  # defence-in-depth, not a live bug) — Users.update_prefs/2 has no clause for
  # a nil user, so guard it here rather than let a bad :user_id crash the
  # channel on what should just be a refused write.
  defp write(socket, attrs) do
    case Users.get(socket.assigns.user_id) do
      nil ->
        {:error, socket}

      user ->
        case Users.update_prefs(user, attrs) do
          {:ok, _user} -> {:ok, push_state(socket)}
          {:error, _changeset} -> {:error, socket}
        end
    end
  end

  # The DB is only half of it: the running FSM is still holding the turn state
  # that was just deleted. Mirrors conversation_live.ex's clear_live_fsm/1.
  defp clear_live_fsm(socket) do
    case Sessions.lookup(to_string(socket.assigns.user_id)) do
      {:ok, pid} -> Conversation.clear_memory(pid)
      :error -> :ok
    end
  end

  # Same nil guard as write/2: reached from join -> :push_state, so a missing
  # user must not crash the channel — that would take the join reply's
  # `{:ok, socket}` down with it after the fact (the client already sees a
  # successful join), leaving a drawer that looks joined but never gets its
  # `state`. Pushing nothing here is that same outcome minus the crash.
  defp push_state(socket) do
    case Users.get(socket.assigns.user_id) do
      nil ->
        socket

      user ->
        push(socket, "state", %{
          default_abi: user.default_abi,
          default_ptt: user.default_ptt,
          voice_activation: user.voice_activation,
          briefing_time: user.briefing_time,
          relock_seconds: user.relock_seconds,
          app_version: App.version()
        })

        socket
    end
  end
end
