defmodule AppWeb.EnrollChannel do
  @moduledoc """
  Voice-Lock enrollment transport: the panel's VoiceEnroll hook streams mic PCM16
  frames here (same binary framing as VoiceChannel), then `clip_done` embeds +
  persists the clip. Join is self-only (topic user must match the socket's token user).
  """
  use AppWeb, :channel

  @impl true
  def join("enroll:" <> uid, _payload, socket) do
    if uid == to_string(socket.assigns.user_id) do
      {:ok, assign(socket, clip: [], clip_bytes: 0)}
    else
      {:error, %{reason: "forbidden"}}
    end
  end

  @impl true
  def handle_in("audio", {:binary, pcm}, socket) do
    %{clip: clip, clip_bytes: bytes} = socket.assigns

    if bytes >= App.Speaker.max_clip_bytes() do
      {:noreply, socket}
    else
      {:noreply, assign(socket, clip: [pcm | clip], clip_bytes: bytes + byte_size(pcm))}
    end
  end

  def handle_in("clip_done", %{"slot" => slot}, socket) when slot in 1..3 do
    pcm = socket.assigns.clip |> Enum.reverse() |> IO.iodata_to_binary()
    socket = assign(socket, clip: [], clip_bytes: 0)

    case App.Speaker.enroll_clip(socket.assigns.user_id, slot, pcm) do
      :ok -> {:reply, {:ok, %{slot: slot}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("clip_reset", _payload, socket),
    do: {:noreply, assign(socket, clip: [], clip_bytes: 0)}
end
