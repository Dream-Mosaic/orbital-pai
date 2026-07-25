defmodule AppWeb.VoiceChannel do
  @moduledoc """
  Bridges a browser to its per-session `Conversation`.

  - **Join** rebinds to a *live* session (the linger keeps it alive across a reload/
    reconnect — conversation state is preserved) via `Conversation.set_client/2`, or
    starts a fresh one if none exists. A start/lookup race resolves to rebinding the
    winner.
  - **Inbound:** binary mic frames (`"audio"`) → `Conversation.push_audio`;
    `"barge_in"` → `Conversation.barge_in`.
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

    case bind_session(session_id) do
      {:ok, pid} ->
        Process.monitor(pid)
        send(self(), :after_join)
        send(self(), {:track_presence, payload["kiosk"] == true})
        {:ok, assign(socket, session_id: session_id, conversation: pid)}

      {:error, reason} ->
        {:error, %{reason: inspect(reason)}}
    end
  end

  # Rebind to a live session (survives reconnects — the linger keeps it alive), else start
  # fresh. A start/lookup race resolves to rebinding the winner.
  defp bind_session(session_id) do
    case Sessions.lookup(session_id) do
      {:ok, pid} ->
        Conversation.set_client(pid, self())
        {:ok, pid}

      :error ->
        case Sessions.start(session_id, self()) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> Conversation.set_client(pid, self()) && {:ok, pid}
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

  def handle_in("barge_in", _payload, socket) do
    Conversation.barge_in(socket.assigns.conversation)
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

  def handle_in("voice_activation", %{"enabled" => enabled}, socket) do
    Conversation.set_voice_activation(socket.assigns.conversation, enabled)
    {:noreply, socket}
  end

  def handle_in("relock", %{"seconds" => seconds}, socket) do
    ms = seconds |> to_int() |> max(10) |> min(30) |> Kernel.*(1000)
    Conversation.set_relock_ms(socket.assigns.conversation, ms)
    {:noreply, socket}
  end

  def handle_in("vision_frame", %{"ref" => ref, "data" => data} = payload, socket)
      when is_integer(ref) and (is_binary(data) or is_nil(data)) do
    # A nil frame means the browser couldn't capture — log the client's reason (getUserMedia error
    # name + camera count) so a wall-kiosk failure is diagnosable from companion.log.
    if is_nil(data) do
      Logger.info(
        "[vision] client sent no frame: #{inspect(Map.get(payload, "error", "(no reason)"))}"
      )
    end

    Conversation.vision_frame(socket.assigns.conversation, ref, data)
    {:reply, :ok, socket}
  end

  # An off-shape vision_frame (client bug) must not crash the channel — ignore it. The
  # Conversation's own 2s :vision_capture timeout then degrades that turn to text-only.
  def handle_in("vision_frame", _payload, socket), do: {:reply, :error, socket}

  # ---- outbound: session -> browser ----
  @impl true
  def handle_info(:after_join, socket) do
    push(socket, "history", %{turns: history(socket.assigns.session_id)})
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

  def handle_info({:to_client, {:capture_frame, ref}}, socket) do
    push(socket, "capture_frame", %{ref: ref})
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

  # W3: server state snapshot on every (re)bind (and initial start) — the hook resets
  # thinking/caption/orb from it so a reconnect can't leave a stale UI.
  def handle_info({:to_client, {:state, snapshot}}, socket) do
    push(socket, "state", snapshot)
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

  # If the bound Conversation dies — a crash, or a linger-expiry we raced during join (set_client is a
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

  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_float(n), do: trunc(n)

  defp to_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> 15
    end
  end

  defp to_int(_), do: 15
end
