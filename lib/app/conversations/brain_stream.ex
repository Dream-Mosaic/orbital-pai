defmodule App.Conversations.BrainStream do
  @moduledoc """
  The streaming brain: Gemini SSE tokens → Cartesia WebSocket → audio chunks.

  Owns one Cartesia TTS websocket for a single brain turn. A linked task streams the
  Gemini reply (`Gemini.stream_brain/4`) and sends us `{:gemini_delta, text}` /
  `{:gemini_done}`; each delta is forwarded to Cartesia (`continue: true`) and also sent to
  the owner as `{:brain_text, delta}` for the live UI caption, and Cartesia's
  audio chunks are forwarded to the owner as `{:brain_audio, pcm}`. When Cartesia signals
  done we send the owner `{:brain_done}` and stop. Any failure sends `{:brain_error, reason}`.

  Run it under a Task.Supervisor-style lifecycle (the Conversation starts/kills it per turn).
  """
  use GenServer
  require Logger

  alias App.Adapters.TextModel.Gemini

  @host "api.cartesia.ai"
  @port 443

  @doc "Start unlinked (the Conversation monitors us instead of linking)."
  def start(opts), do: GenServer.start(__MODULE__, opts)
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Supply the transcript to a pre-warmed (transcript-less) stream. The Gemini call starts once
  BOTH the Cartesia WS is ready and the transcript has arrived.
  """
  def begin(pid, transcript, recent_context),
    do: GenServer.cast(pid, {:begin, transcript, recent_context})

  @impl true
  def handle_cast({:begin, transcript, recent_context}, state) do
    state = %{state | transcript: transcript, recent_context: recent_context}

    if state.ready and is_nil(state.gemini_task),
      do: {:noreply, start_gemini(state)},
      else: {:noreply, state}
  end

  @impl true
  def init(opts) do
    # Trap exits so terminate/2 always runs (close the Cartesia WS + kill the Gemini task)
    # and so the owner's Process.exit(:shutdown) is a graceful stop, not a brutal kill.
    Process.flag(:trap_exit, true)

    state = %{
      owner: Keyword.fetch!(opts, :owner),
      transcript: Keyword.get(opts, :transcript),
      session_id: Keyword.get(opts, :session_id),
      # include recent conversation turns in the brain context? false for reminder turns, so a
      # fired reminder is fulfilled in isolation (no conversation bleed / repetition).
      recent_context: Keyword.get(opts, :recent_context, true),
      config: Keyword.fetch!(opts, :config),
      # Cartesia context base + a sequence we bump on each expiry. A context auto-expires 1s after
      # its last AUDIO output (Cartesia docs), so a long tool round (silent bridge→answer gap) kills
      # the bridge's context before the answer arrives. We can't keep it alive (no keepalive exists,
      # and the expiry is audio-based), so instead we let it die and stream the answer on a FRESH
      # context_id — Cartesia supports many contexts per connection.
      context_base: Keyword.get(opts, :context_id, "brain"),
      context_seq: 0,
      conn: nil,
      websocket: nil,
      request_ref: nil,
      status: nil,
      resp_headers: nil,
      ready: false,
      # text deltas that arrived before the WS finished its handshake
      pending: [],
      gemini_done: false,
      # accumulated reply text (for the turn log + memory persistence)
      text: "",
      # the linked Gemini SSE task (so we can shut it down on teardown)
      gemini_task: nil
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case connect(state) do
      {:ok, state} -> {:noreply, state}
      {:error, reason} -> stop_error(reason, state)
    end
  end

  defp connect(state) do
    query =
      URI.encode_query(%{
        cartesia_version: state.config.cartesia_version,
        api_key: System.fetch_env!("CARTESIA_API_KEY")
      })

    path = "/tts/websocket?" <> query

    with {:ok, conn} <- Mint.HTTP.connect(:https, @host, @port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(:wss, conn, path, []) do
      {:ok, %{state | conn: conn, request_ref: ref}}
    end
  end

  # ---- Gemini task messages ----
  @impl true
  def handle_info({:gemini_delta, text}, %{ready: false} = state) do
    send(state.owner, {:brain_text, text})
    {:noreply, %{state | pending: [text | state.pending], text: state.text <> text}}
  end

  def handle_info({:gemini_delta, text}, state) do
    send(state.owner, {:brain_text, text})
    {:noreply, send_text(%{state | text: state.text <> text}, text, true)}
  end

  # A "bridge" filler spoken while a tool runs: forward to Cartesia like a delta, but do NOT
  # accumulate it into `state.text` — it must not reach captions, the final answer, or memory.
  # best-effort: if Cartesia isn't ready yet the phrase is silently dropped (no pending buffer — by
  # the time the WS connects the brain has already moved on to executing the tool).
  def handle_info({:gemini_bridge, _text}, %{ready: false} = state), do: {:noreply, state}

  def handle_info({:gemini_bridge, text}, state) do
    {:noreply, send_text(state, text, true)}
  end

  def handle_info({:gemini_done}, %{ready: false} = state),
    do: {:noreply, %{state | gemini_done: true}}

  # No answer text at all (e.g. a bridge played, then the brain produced nothing) — don't depend on
  # Cartesia to `done` a possibly-empty/rotated context; finish now so the turn ends (and B2 speaks
  # its canned line) instead of stalling to the watchdog. Stay alive like the normal done path —
  # the owner clears + terminates us (avoids racing its {:DOWN} handler into a spurious fallback).
  def handle_info({:gemini_done}, %{text: ""} = state) do
    send(state.owner, {:brain_done, ""})
    {:noreply, state}
  end

  def handle_info({:gemini_done}, state) do
    # flush: tell Cartesia this context is complete; it will finish + send `done`.
    {:noreply, send_text(%{state | gemini_done: true}, "", false)}
  end

  def handle_info({:gemini_error, reason}, state), do: stop_error(reason, state)

  # ---- trapped exits (must precede the Mint catch-all) ----
  # the Gemini task finished/exited — fine, it already sent its delta/done/error
  def handle_info({:EXIT, pid, _reason}, %{gemini_task: pid} = state), do: {:noreply, state}
  # the owner asked us to stop (Process.exit on barge-in/complete)
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  # ---- Mint / websocket ----
  def handle_info(message, %{conn: conn} = state) when not is_nil(conn) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        {:noreply, Enum.reduce(responses, %{state | conn: conn}, &handle_response/2)}

      {:error, conn, reason, _responses} ->
        stop_error(reason, %{state | conn: conn})

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- upgrade handshake ----
  defp handle_response({:status, ref, status}, %{request_ref: ref} = state),
    do: %{state | status: status}

  defp handle_response({:headers, ref, headers}, %{request_ref: ref} = state),
    do: %{state | resp_headers: headers}

  defp handle_response({:done, ref}, %{request_ref: ref, status: 101} = state) do
    case Mint.WebSocket.new(state.conn, ref, state.status, state.resp_headers) do
      {:ok, conn, websocket} ->
        state = %{state | conn: conn, websocket: websocket, ready: true}
        if state.transcript, do: start_gemini(state), else: state

      {:error, conn, reason} ->
        send(self(), {:gemini_error, reason})
        %{state | conn: conn}
    end
  end

  defp handle_response({:done, ref}, %{request_ref: ref, status: status} = state) do
    send(self(), {:gemini_error, {:cartesia_status, status}})
    state
  end

  defp handle_response({:data, ref, data}, %{request_ref: ref, websocket: ws} = state)
       when not is_nil(ws) do
    case Mint.WebSocket.decode(ws, data) do
      {:ok, ws, frames} -> Enum.reduce(frames, %{state | websocket: ws}, &handle_frame/2)
      {:error, ws, _reason} -> %{state | websocket: ws}
    end
  end

  defp handle_response(_other, state), do: state

  # On WS ready: flush any buffered deltas (oldest first), then start the Gemini stream.
  defp start_gemini(state) do
    state =
      state.pending
      |> Enum.reverse()
      |> Enum.reduce(%{state | pending: []}, fn text, st -> send_text(st, text, true) end)

    if state.gemini_done do
      send_text(state, "", false)
    else
      pid = self()
      transcript = state.transcript
      sid = state.session_id
      cfg = state.config
      recent? = state.recent_context

      {:ok, task} =
        Task.start_link(fn ->
          # Load memory context off this process; inject only into the brain tier. Reminder
          # turns pass recent_context: false → profile/summary kept, conversation turns dropped.
          ctx = if sid, do: App.Memory.context(sid, recent: recent?), else: %{}

          Logger.info(
            "[turn] brain-context: #{length(Map.get(ctx, :recent, []))} recent turns, " <>
              "summary #{String.length(Map.get(ctx, :summary, ""))} chars"
          )

          Gemini.stream_brain(
            transcript,
            ctx,
            [config: cfg, thinking: cfg.brain_thinking, session_id: sid],
            pid
          )
        end)

      %{state | gemini_task: task}
    end
  end

  # ---- Cartesia frames ----
  # (public for unit tests — exercised live via the Mint WS reduce above)
  @doc false
  def handle_frame({:text, text}, state) do
    case Jason.decode(text) do
      {:ok, %{"type" => "chunk", "data" => b64}} ->
        # Tolerate a malformed/truncated chunk instead of crashing the whole stream
        # (mirrors the lenient decode below). One bad chunk shouldn't abort the reply.
        case Base.decode64(b64) do
          {:ok, pcm} -> send(state.owner, {:brain_audio, pcm})
          :error -> Logger.warning("[brain] dropped a malformed audio chunk")
        end

        state

      {:ok, %{"type" => "done"}} when not state.gemini_done ->
        # A context expired 1s after its last audio (Cartesia docs) while the brain is STILL working
        # — the classic case is a tool bridge that played, then a long silent tool gap. Don't end the
        # turn: rotate to a fresh context_id so the answer (when it lands) streams on a live context.
        Logger.info(
          "[brain] cartesia context expired mid-turn (#{current_context(state)}); " <>
            "rotating — brain not done yet"
        )

        %{state | context_seq: state.context_seq + 1}

      {:ok, %{"type" => "done"}} ->
        Logger.info("[brain] cartesia done; answer #{String.length(state.text)} chars")
        send(state.owner, {:brain_done, state.text})
        # caller will terminate us; nothing more to do
        state

      {:ok, %{"type" => "error"} = msg} ->
        Logger.warning("[brain] cartesia error: #{inspect(msg)}")
        send(state.owner, {:brain_error, {:cartesia, msg}})
        state

      _ ->
        state
    end
  end

  # a remote close frame: finish with whatever we have rather than stalling to the watchdog
  def handle_frame({:close, _code, _reason}, state) do
    Logger.info(
      "[brain] cartesia closed; answer #{String.length(state.text)} chars, " <>
        "gemini_done=#{state.gemini_done}"
    )

    if state.text == "",
      do: send(state.owner, {:brain_error, :cartesia_closed}),
      else: send(state.owner, {:brain_done, state.text})

    state
  end

  def handle_frame(_frame, state), do: state

  # ---- send text to Cartesia ----
  defp send_text(state, transcript, continue) do
    msg = tts_message(state.config, transcript, continue, current_context(state))

    case send_frame(state, {:text, Jason.encode!(msg)}) do
      {:ok, state} -> state
      {:error, state, _reason} -> state
    end
  end

  # The live Cartesia context id; bumped each time one expires mid-turn (see the done handler).
  defp current_context(state), do: "#{state.context_base}-#{state.context_seq}"

  @doc false
  def tts_message(config, transcript, continue, context_id) do
    %{
      model_id: config.tts_model,
      transcript: transcript,
      continue: continue,
      context_id: context_id,
      voice: %{mode: "id", id: config.voice_id},
      generation_config:
        App.Adapters.Tts.Cartesia.generation_config(
          config.tts_speed,
          config.tts_volume,
          config.tts_emotion
        ),
      output_format: %{
        container: "raw",
        encoding: "pcm_s16le",
        sample_rate: config.tts_sample_rate
      }
    }
  end

  defp send_frame(state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data) do
      {:ok, %{state | conn: conn, websocket: websocket}}
    else
      {:error, ws_or_conn, reason} ->
        {:error, %{state | websocket: keep_ws(ws_or_conn, state)}, reason}
    end
  end

  defp keep_ws(%Mint.WebSocket{} = ws, _state), do: ws
  defp keep_ws(_other, state), do: state.websocket

  defp stop_error(reason, state) do
    send(state.owner, {:brain_error, reason})
    {:stop, :normal, state}
  end

  # Always-run cleanup (trap_exit guarantees this on every stop path): kill the linked
  # Gemini task (a {:stop, :normal} wouldn't propagate to it) and close the Cartesia socket.
  @impl true
  def terminate(_reason, state) do
    if is_pid(state.gemini_task) and Process.alive?(state.gemini_task),
      do: Process.exit(state.gemini_task, :kill)

    if state.conn, do: Mint.HTTP.close(state.conn)
    :ok
  end
end
