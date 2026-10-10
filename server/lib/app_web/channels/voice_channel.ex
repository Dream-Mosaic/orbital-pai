defmodule AppWeb.VoiceChannel do
  @moduledoc """
  Bridges the app to its per-session `Conversation`.

  - **Join** resolves the user's *live* session (the linger keeps it alive across a reload/
    reconnect — conversation state is preserved), or starts a fresh one if none exists; a
    start/lookup race resolves to the winner. It then always casts `Conversation.join/2`
    with this channel's `device_id`, and the FSM decides whether this channel becomes the
    bound one or joins **standby** (connected and fed state, but not the audio owner, until
    it claims by speaking). Either way the channel gets a `state` snapshot carrying `bound`.
  - **Inbound:** binary mic frames (`"audio"`) → `Conversation.push_audio`.
  - **Outbound:** the Conversation sends `{:to_client, msg}` to this channel; each is
    relayed to the browser as a JSON event (`speak_start` / `metrics` / `transcript` /
    `stop_playback` / `state`) — except `audio`, which is pushed as a raw binary
    channel frame (no JSON envelope, no base64).
  - **Terminate** does NOT stop the session outright — it tells the Conversation this
    channel disconnected (`Conversation.client_disconnected/2`, pid-guarded so a stale
    channel closing after another rebound can't kill the live one); the Conversation
    arms a linger and stops itself only if nothing rebinds in time.
  """
  use AppWeb, :channel
  require Logger

  alias App.Conversations.{Conversation, Sessions}

  @history_turns 12

  @impl true
  def join("voice:" <> _ignored, payload, socket) do
    session_id = to_string(socket.assigns.user_id)

    case resolve_session(session_id) do
      {:ok, pid} ->
        Conversation.join(pid, payload["device_id"])
        Process.monitor(pid)
        send(self(), :after_join)
        send(self(), {:track_presence, payload["kiosk"] == true})

        {:ok,
         assign(socket,
           session_id: session_id,
           conversation: pid,
           voice_defaults: voice_defaults(socket.assigns.user_id)
         )}

      {:error, reason} ->
        {:error, %{reason: inspect(reason)}}
    end
  end

  # Find the user's live session (it survives reconnects — the linger keeps it alive), else
  # start one. A start/lookup race resolves to the winner. Binding is NOT decided here: join/3
  # casts `Conversation.join/2` on every path and the FSM decides, so there is no
  # lookup -> decide -> cast race.
  defp resolve_session(session_id) do
    case Sessions.lookup(session_id) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        case Sessions.start(session_id, self()) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # The persisted transcript tail, oldest-first, for the client to backfill the log.
  defp history(session_id) do
    case App.Users.id_from_session(session_id) do
      nil ->
        []

      user_id ->
        user_id
        |> App.Memory.recent_turns(@history_turns)
        |> Enum.map(fn t ->
          %{you: t.user_text, assistant: t.brain_text, at: DateTime.to_iso8601(t.inserted_at)}
        end)
    end
  end

  # ---- inbound: browser -> session ----
  @impl true
  def handle_in("audio", {:binary, pcm}, socket) do
    Conversation.push_audio(socket.assigns.conversation, pcm)
    {:noreply, socket}
  end

  def handle_in("played", %{"ms" => ms}, socket) when is_number(ms) do
    Conversation.played(socket.assigns.conversation, ms)
    {:noreply, socket}
  end

  def handle_in("ptt", %{"enabled" => enabled}, socket) do
    Conversation.set_ptt(socket.assigns.conversation, enabled)
    {:noreply, socket}
  end

  def handle_in("ptt_press", _payload, socket) do
    Conversation.ptt_press(socket.assigns.conversation)
    {:noreply, socket}
  end

  def handle_in("ptt_release", _payload, socket) do
    Conversation.ptt_release(socket.assigns.conversation)
    {:noreply, socket}
  end

  def handle_in("allow_interruptions", %{"enabled" => enabled}, socket) do
    Conversation.set_allow_interruptions(socket.assigns.conversation, enabled)
    {:noreply, socket}
  end

  # The thread's inline Ack chip on a delivered reminder. Rides THIS topic because it is the
  # one every client always holds -- panel:reminders is joined only while its drawer is open,
  # so an ack tapped in the thread had nowhere to go (issue #4). Same rule as
  # RemindersChannel.handle_in("ack"): the id is resolved against the user's OWN due list
  # (which already includes household rows), never Repo.get/2.
  def handle_in("ack_reminder", %{"id" => id}, socket) when is_integer(id) do
    case Enum.find(App.Reminders.list_unacknowledged(socket.assigns.user_id), &(&1.id == id)) do
      nil ->
        {:reply, {:error, %{reason: "not_found"}}, socket}

      reminder ->
        App.Reminders.acknowledge(reminder)
        {:reply, :ok, socket}
    end
  end

  # An off-shape ack (client bug) must not crash the channel.
  def handle_in("ack_reminder", _payload, socket),
    do: {:reply, {:error, %{reason: "bad_request"}}, socket}

  # The voice screen's trash detent (issue #9): clears the SERVER conversation, same as
  # Settings > Clear conversation. Rides this topic for the ack_reminder reason -- the detent
  # is used with no drawer open, so panel:settings is not joined. Mirrors SettingsChannel's
  # clear_turns: the DB delete plus a reset of the live FSM's turn state.
  def handle_in("clear_turns", _payload, socket) do
    App.Memory.clear_turns(socket.assigns.user_id)
    Conversation.clear_memory(socket.assigns.conversation)
    {:reply, :ok, socket}
  end

  def handle_in("wake_detected", _payload, socket) do
    Conversation.wake_detected(socket.assigns.conversation)
    {:noreply, socket}
  end

  # A TYPED message (spec 2026-10-10 household wave 1, F1), answered quietly in text. The
  # thread's "you" line comes back as the ordinary `transcript` push, so the sender never
  # draws an optimistic copy and every device renders it exactly once.
  @max_typed_chars 2_000

  def handle_in("text", %{"text" => text}, socket) when is_binary(text) do
    case String.trim(text) do
      "" -> :ok
      t -> Conversation.typed(socket.assigns.conversation, String.slice(t, 0, @max_typed_chars))
    end

    {:noreply, socket}
  end

  def handle_in("text", _payload, socket), do: {:noreply, socket}

  # The timer strip's taps (tap a ringing chip / long-press a running one). Scoped to THIS
  # socket's user inside App.Timers, so an id belonging to someone else is just not_found.
  def handle_in(event, %{"id" => id}, socket)
      when event in ["dismiss_timer", "cancel_timer"] and is_integer(id) do
    uid = socket.assigns.user_id

    result =
      if event == "dismiss_timer",
        do: App.Timers.dismiss(uid, id),
        else: App.Timers.cancel(uid, id)

    case result do
      {:ok, _} -> {:reply, :ok, socket}
      {:error, _} -> {:reply, {:error, %{reason: "not_found"}}, socket}
    end
  end

  def handle_in(event, _payload, socket) when event in ["dismiss_timer", "cancel_timer"],
    do: {:reply, {:error, %{reason: "bad_request"}}, socket}

  # ---- outbound: session -> browser ----
  @impl true
  def handle_info(:after_join, socket) do
    push(socket, "history", %{turns: history(socket.assigns.session_id)})
    # Timers are per USER, not per conversation: every device of the user watches them
    # directly (no Conversation involvement). Subscribe BEFORE reading, so a change landing
    # in between still re-pushes.
    Phoenix.PubSub.subscribe(App.PubSub, "timers:#{socket.assigns.user_id}")
    send(self(), :refresh_glance)
    {:noreply, push_timers(socket)}
  end

  def handle_info({:timers_changed, _user_id}, socket), do: {:noreply, push_timers(socket)}

  # The idle orb's weather + next event (App.Glance). Built OFF the channel process — it runs
  # real tools (weather, a multi-account calendar fan-out) — and refreshed every 5 minutes;
  # the tool cache makes a refresh that lands inside a TTL free. Off in test (`:glance`).
  @glance_refresh_ms 5 * 60 * 1000

  def handle_info(:refresh_glance, socket) do
    if Application.get_env(:app, :glance, true) do
      me = self()
      uid = socket.assigns.user_id

      Task.Supervisor.start_child(App.Conversations.TaskSup, fn ->
        send(me, {:glance, App.Glance.build(uid)})
      end)

      Process.send_after(self(), :refresh_glance, @glance_refresh_ms)
    end

    {:noreply, socket}
  end

  def handle_info({:glance, glance}, socket) do
    push(socket, "glance", glance)
    {:noreply, socket}
  end

  # Tracked via handle_info (not inline in join/3) so join returns fast; Presence auto-untracks
  # on channel death, so no terminate change is needed.
  def handle_info({:track_presence, kiosk?}, socket) do
    user = App.Users.get(socket.assigns.user_id)

    {:ok, _} =
      AppWeb.Presence.track(self(), "presence:voice", to_string(socket.assigns.user_id), %{
        name: user && user.name,
        kiosk: kiosk?,
        online_at: System.system_time(:second)
      })

    {:noreply, socket}
  end

  def handle_info({:to_client, {:speak_start, source, text}}, socket) do
    push(socket, "speak_start", %{source: source, text: text})
    {:noreply, socket}
  end

  # A just-delivered reminder's id — the client attaches an inline "Ack" chip to its transcript line.
  def handle_info({:to_client, {:reminder_ack_offer, id}}, socket) do
    push(socket, "reminder_ack_offer", %{id: id})
    {:noreply, socket}
  end

  def handle_info({:to_client, {:audio, _source, pcm}}, socket) do
    # Raw PCM as a binary channel frame — no base64 (25% smaller, no client-side atob loop).
    # The client ignores the source for audio (speak_start carries the labeled text).
    push(socket, "audio", {:binary, pcm})
    {:noreply, socket}
  end

  def handle_info({:to_client, {:brain_delta, delta}}, socket) do
    push(socket, "brain_delta", %{delta: delta})
    {:noreply, socket}
  end

  def handle_info({:to_client, {:tool_call, name}}, socket) do
    push(socket, "tool_call", %{name: name})
    {:noreply, socket}
  end

  # A visual answer (App.Cards): already display-ready, so the client only lays it out.
  def handle_info({:to_client, {:card, card}}, socket) do
    push(socket, "card", %{card: card})
    {:noreply, socket}
  end

  def handle_info({:to_client, {:metrics, ttfa, ttb}}, socket) do
    push(socket, "metrics", %{ttfa: ttfa, ttb: ttb})
    {:noreply, socket}
  end

  def handle_info({:to_client, {:partial, text}}, socket) do
    push(socket, "partial", %{text: text})
    {:noreply, socket}
  end

  def handle_info({:to_client, :speaking}, socket) do
    push(socket, "speaking", %{})
    {:noreply, socket}
  end

  def handle_info({:to_client, :listening}, socket) do
    push(socket, "listening", %{})
    {:noreply, socket}
  end

  def handle_info({:to_client, :thinking}, socket) do
    push(socket, "thinking", %{})
    {:noreply, socket}
  end

  def handle_info({:to_client, {:locked, locked}}, socket) do
    push(socket, "locked", %{locked: locked})
    {:noreply, socket}
  end

  # Handoff: this channel gained (or lost) ownership of the conversation. Kept separate from
  # `locked` on purpose — "I am not the owner" and "the wake gate is shut" are different facts.
  #
  # Gaining ownership also re-syncs the on-screen thread: history only ever backfills once, at
  # :after_join, so a device that has been sitting in standby while the conversation roamed
  # elsewhere has a thread frozen at join time even though the FSM's context is current (shared
  # memory, divergent displays). Push a fresh `history` alongside `bound`, flagged `replace: true`
  # so the client knows to rebuild the thread instead of appending to it. (Known and accepted: turns
  # persist in a background task while this reads the DB, so a claim landing within a moment of the
  # previous turn's end can miss that last turn.)
  def handle_info({:to_client, {:bound, true}}, socket) do
    push(socket, "bound", %{bound: true})
    push(socket, "history", %{turns: history(socket.assigns.session_id), replace: true})
    {:noreply, socket}
  end

  def handle_info({:to_client, {:bound, false}}, socket) do
    push(socket, "bound", %{bound: false})
    {:noreply, socket}
  end

  # W3: server state snapshot on every (re)bind (and initial start) — the hook resets
  # thinking/caption/orb from it so a reconnect can't leave a stale UI.
  #
  # The snapshot also carries the user's stored voice defaults. The web stamps these into the
  # page (`data-default-ptt`/`data-default-abi`) and applies them at load; the native client has
  # no such channel and only ever learned them from the Settings drawer, which is joined ONLY
  # while that drawer is on screen — so at launch it had no idea what the defaults were and the
  # prefs looked like they never persisted. This is the one push every client already receives
  # on join, so it costs no extra round trip.
  def handle_info({:to_client, {:state, snapshot}}, socket) do
    push(socket, "state", Map.merge(snapshot, socket.assigns.voice_defaults))
    {:noreply, socket}
  end

  def handle_info({:to_client, {:transcript, text}}, socket) do
    push(socket, "transcript", %{text: text})
    {:noreply, socket}
  end

  def handle_info({:to_client, :stop_playback}, socket) do
    push(socket, "stop_playback", %{})
    {:noreply, socket}
  end

  def handle_info({:to_client, :duck}, socket) do
    push(socket, "duck", %{})
    {:noreply, socket}
  end

  def handle_info({:to_client, :unduck}, socket) do
    push(socket, "unduck", %{})
    {:noreply, socket}
  end

  def handle_info({:to_client, {:voice_gate, decision}}, socket) do
    push(socket, "voice_gate", %{decision: decision})
    {:noreply, socket}
  end

  # If the bound Conversation dies — a crash, or a linger-expiry we raced during join (the join is a
  # cast, so a lookup→dead-pid gap is possible) — drop this channel so the browser's auto-rejoin starts a
  # fresh session instead of talking silently to a dead pid.
  def handle_info({:DOWN, _ref, :process, pid, reason}, socket) do
    if pid == Map.get(socket.assigns, :conversation) do
      Logger.info(
        "[conn] bound conversation down (#{inspect(reason)}) — dropping channel for a fresh rejoin"
      )

      {:stop, :shutdown, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def terminate(reason, socket) do
    # The header dot goes amber when THIS channel dies on the client. Logging the reason here
    # (companion.log is the diagnostic surface) lets us line a yellow flash up against its cause:
    # {:shutdown, :closed}/:left = clean tab/socket close (mobile backgrounding, roam); anything
    # else = an actual crash worth chasing.
    Logger.info(
      "[conn] voice:#{Map.get(socket.assigns, :session_id, "?")} channel terminate: #{inspect(reason)}"
    )

    case socket.assigns do
      %{conversation: pid} when is_pid(pid) -> Conversation.client_disconnected(pid, self())
      _ -> :ok
    end

    :ok
  end

  # Read ONCE, in join/3, and carried in assigns — never per push. The `state` snapshot goes
  # out on every (re)bind, so resolving it in the push path put a DB round trip on a hot path
  # that had none, on a device that rejoins after every wifi blip.
  #
  # join/3 rather than the :after_join path, even though that path already loads this user:
  # the snapshot can be AHEAD of it in the mailbox, and on a cold start always is. The FSM
  # sends it from `Sessions.start`'s `init/1` (conversation.ex:257) — which runs inside
  # `resolve_session`, before join/3 gets as far as `send(self(), :after_join)` — and on the
  # warm path from the `{:join, …}` cast, which is issued two lines earlier still.
  #
  # Absent keys rather than false ones when the row is gone: every client treats a MISSING
  # snapshot key as "don't touch what I already know" (see `bound`/`phase`), and a vanished
  # user must not read as "both defaults off".
  defp voice_defaults(user_id) do
    case App.Users.get(user_id) do
      nil -> %{}
      user -> %{default_abi: user.default_abi, default_ptt: user.default_ptt}
    end
  end

  # remaining_ms is computed at push time, so each device anchors its countdown to its own
  # clock (no server/device skew).
  defp push_timers(socket) do
    push(socket, "timers", %{timers: App.Timers.wire(socket.assigns.user_id)})
    socket
  end
end
