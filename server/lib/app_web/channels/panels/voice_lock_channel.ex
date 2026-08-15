defmodule AppWeb.Panels.VoiceLockChannel do
  @moduledoc """
  The native Voice Lock drawer's STATE path. Joined only while the Voice Lock
  LAYER is visible inside the Settings drawer. The AUDIO path is
  `AppWeb.EnrollChannel`, joined separately and per recording.

  Non-essential: a refusal stops this channel and leaves the conversation alone.

  This channel RIDES THE BROADCAST. `App.Speaker.broadcast_changed/1`
  (`speaker.ex:180-181`) publishes the ONE-ELEMENT tuple `{:voice_lock_changed}`
  on the PER-USER topic `voice_lock:<user_id>` — a genuine per-user topic,
  unlike `App.Memory`'s global one, so there are no cross-user wakeups here.
  Verified which functions publish it, by reading `speaker.ex` rather than
  assuming:

    * `enroll_clip/3` — YES, `speaker.ex:38`, on success inside the `with`
    * `set_mode/2`   — YES, `speaker.ex:119`, on success
    * `log_event/1`  — NO (`speaker.ex:126-148`)

  So `set_mode` mutates and lets the re-push come back to it; it must NOT push
  `state` itself, or one tap renders twice.

  KNOWN LIMITATION, documented not fixed (spec §7): because `log_event/1` does
  not broadcast, a gate drop does NOT refresh an open panel — "Recently
  filtered" updates on join, on a mode change, and on an enrollment only. The
  web behaves identically. The cure is one line at the end of `log_event/1`,
  but that runs on the turn HOT PATH in shadow mode for every scored turn, so
  it deserves its own think about volume rather than a drive-by.

  The live `Conversation` FSM subscribes to the same per-user topic and reloads
  its own cache (`conversation.ex:203, 424-425`), so a mode change reaches a
  running session with no help from this channel. Do NOT add a
  `Conversation.*` poke here the way `SettingsChannel` needs one for relock.

  `state` carries `user_id` — an addition to the design's §5 payload, made on
  purpose. The native client has no user id (every topic it opens hardcodes an
  ignored `henry` suffix), and `enroll:<uid>` is self-only: `EnrollChannel`
  compares the topic suffix to the token user and refuses a mismatch. This is
  the only place the client can learn it, and it is a field on OUR channel, so
  §2 Scope ("no change to App.Speaker, EnrollChannel, or the gate") holds.
  """
  use AppWeb, :channel

  alias App.Speaker
  alias App.Users

  # The mode allowlist is this channel's whole authorisation story. Matched
  # LITERALLY before the value can reach Speaker.set_mode/2, whose own guard
  # (`when mode in ~w(off shadow enforce)`) protects the DATA but not the
  # channel: an unmatched call raises FunctionClauseError and kills the
  # channel process, dropping the panel. Mutation-tested.
  @modes ~w(off shadow enforce)

  @impl true
  def join("panel:voice_lock:" <> _ignored, _payload, socket) do
    # The suffix is ignored; the user is whoever the token authenticated.
    Phoenix.PubSub.subscribe(App.PubSub, "voice_lock:#{socket.assigns.user_id}")
    send(self(), :push_state)
    {:ok, socket}
  end

  @impl true
  def handle_in("set_mode", %{"mode" => mode}, socket) when mode in @modes do
    # No push_state here: set_mode/2 broadcasts on success and the join/2
    # subscription above re-pushes to us AND to any open web LiveView.
    case Users.get(socket.assigns.user_id) do
      nil ->
        {:reply, {:error, %{reason: "bad_request"}}, socket}

      user ->
        case Speaker.set_mode(user, mode) do
          {:ok, _user} -> {:reply, :ok, socket}
          {:error, _changeset} -> {:reply, {:error, %{reason: "bad_request"}}, socket}
        end
    end
  end

  # A client bug — or a probe — must not crash the channel and drop the panel.
  # Also catches every `set_mode` whose mode is not in @modes.
  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{reason: "bad_request"}}, socket}

  @impl true
  def handle_info(:push_state, socket), do: {:noreply, push_state(socket)}
  def handle_info({:voice_lock_changed}, socket), do: {:noreply, push_state(socket)}

  # Same nil guard as SettingsChannel's: reached from join -> :push_state, so a
  # missing user must not crash the channel after the client already saw a
  # successful join reply.
  defp push_state(socket) do
    uid = socket.assigns.user_id

    case Users.get(uid) do
      nil ->
        socket

      user ->
        push(socket, "state", %{
          user_id: uid,
          # The RAW string, as users.voice_lock_mode stores it.
          # Speaker.mode_atom/1 is private and is for the FSM, not the wire.
          mode: user.voice_lock_mode,
          enrolled_slots: Speaker.enrolled_slots(uid),
          verifier_ready: Speaker.verifier().ready?(),
          drops: Enum.map(Speaker.recent_drops(uid), &drop/1)
        })

        socket
    end
  end

  # Exactly three keys — no struct dump. `score` is a nullable float
  # (gate_event.ex:9) and crosses as null; the client tolerates it.
  defp drop(e), do: %{decision: e.decision, transcript: e.transcript, score: e.score}
end
