defmodule AppWeb.VoiceChannel do
  @moduledoc """
  Bridges a browser to its per-session `Conversation`.

  - **Join** (re)starts the session bound to *this* channel as the Conversation's
    `client`. Any stale session is dropped first, so a reload never leaves the
    Conversation pushing audio at a dead pid.
  - **Inbound:** binary mic frames (`"audio"`) → `Conversation.push_audio`;
    `"barge_in"` → `Conversation.barge_in`.
  - **Outbound:** the Conversation sends `{:to_client, msg}` to this channel; each is
    relayed to the browser as a JSON event (`speak_start` / `metrics` / `transcript` /
    `stop_playback`) — except `audio`, which is pushed as a raw binary channel frame
    (no JSON envelope, no base64).
  - **Terminate** stops the session (which also tears down its STT websocket).
  """
  use AppWeb, :channel
  require Logger

  alias App.Conversations.{Conversation, Sessions}

  @impl true
  def join("voice:" <> _ignored, _payload, socket) do
    session_id = to_string(socket.assigns.user_id)

    case bind_session(session_id) do
      {:ok, pid} -> {:ok, assign(socket, session_id: session_id, conversation: pid)}
      {:error, reason} -> {:error, %{reason: inspect(reason)}}
    end
  end

  # Bind a fresh session to THIS channel. We stop any prior one first (so the Conversation's
  # client points at us), but the Registry unregisters asynchronously after terminate, so a
  # fast rejoin can still hit {:already_started}; retry briefly, then fall back to the
  # existing pid rather than crashing the join.
  defp bind_session(session_id, tries \\ 5) do
    Sessions.stop(session_id)

    case Sessions.start(session_id, self()) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} when tries <= 0 ->
        {:ok, pid}

      {:error, {:already_started, _pid}} ->
        Process.sleep(20)
        bind_session(session_id, tries - 1)

      {:error, reason} ->
        {:error, reason}
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

  # ---- outbound: session -> browser ----
  @impl true
  def handle_info({:to_client, {:speak_start, source, text}}, socket) do
    push(socket, "speak_start", %{source: source, text: text})
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
      %{session_id: sid} -> Sessions.stop(sid)
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
