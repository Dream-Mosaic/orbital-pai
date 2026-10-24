defmodule App.Adapters.Stt.Cartesia do
  @moduledoc """
  Cartesia **Ink-2** live streaming STT over `Mint.WebSocket`. Holds the WS for one
  session, forwards `{:stt_partial, t}` / `{:stt_endpoint, t}` to the owner (the
  Conversation), and accepts PCM16 frames via `push/2`.

  Ink-2 splits turn-taking across two endpoints, selected by the start `:mode`:

    * `:auto` — `/stt/turns/websocket`, native **semantic** turn detection. `turn.update`
      previews (cumulative); `turn.end` ends the user's turn. Hands-free.
    * `:manual` — `/stt/websocket`, push-to-talk. `transcript` (is_final) segments
      accumulate; a release-driven bare `finalize` flushes them and the `flush_done` ack
      ends the turn — so a long hold stays whole across mid-hold pauses.

  The PTT toggle reconnects the STT socket in the matching mode.

  The auto socket is opened with `:turn_end_threshold` (`App.Config :stt_turn_end_threshold`)
  when set: how sure Ink must be that the user is done before it sends `turn.end`. The manual
  socket has no turn detection, so it never gets the parameter. An Ink `error` event (a
  rejected parameter, say) is logged as `[stt] Ink error` and passed on as `{:stt_error, _}`.

  No keepalive: unlike Deepgram, Ink has no KeepAlive message. An idle socket clean-closes
  (Ink's ~3-min idle timeout); that stops this process `:normal` and the Conversation
  reconnects on the next mic frame — so an idle PTT gap is recovered, not fatal.

  Frames pushed before the upgrade completes are HELD and sent in order once the socket is
  up (bounded by `:pending_max_bytes`, oldest dropped first). The reconnect after an idle
  close is started by the very frame that carries the wake pre-roll and the user's first
  words; dropping frames until ready clipped the front of every utterance spoken after
  ~3 minutes of quiet ("Henry, what do I have…" heard as "have…").
  """

  @behaviour App.Adapters.Stt
  use GenServer
  require Logger

  @url "https://api.cartesia.ai"

  # 8 s of 16 kHz PCM16: far past a cold connect, small enough to never matter.
  @pending_seconds 8

  @typedoc "Router accumulator: {committed final segments (manual), latest interim}."
  @type acc :: {[String.t()], String.t()}

  # ---- behaviour API ----
  @impl App.Adapters.Stt
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl App.Adapters.Stt
  def push(pid, pcm16), do: GenServer.cast(pid, {:push, pcm16})

  @impl App.Adapters.Stt
  def finalize(pid), do: GenServer.cast(pid, :finalize)

  # ---- GenServer ----
  @impl GenServer
  def init(opts) do
    sample_rate = Keyword.get(opts, :sample_rate, 16_000)

    state = %{
      owner: Keyword.fetch!(opts, :owner),
      mode: Keyword.get(opts, :mode, :auto),
      # the test seam: a local fake Ink speaks plain http/ws
      url: Keyword.get(opts, :url, @url),
      sample_rate: sample_rate,
      model: Keyword.get(opts, :model, "ink-2"),
      version: Keyword.get(opts, :version, "2026-06-24"),
      # auto only; nil = Ink's default
      turn_end_threshold: Keyword.get(opts, :turn_end_threshold),
      conn: nil,
      websocket: nil,
      request_ref: nil,
      status: nil,
      resp_headers: nil,
      # router accumulator: {committed segments, latest interim}
      acc: {[], ""},
      # frames pushed before the upgrade completed, oldest first
      pending: :queue.new(),
      pending_bytes: 0,
      pending_max_bytes: Keyword.get(opts, :pending_max_bytes, sample_rate * 2 * @pending_seconds)
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    case connect(state) do
      {:ok, state} -> {:noreply, state}
      {:error, reason} -> {:stop, {:connect_failed, reason}, state}
    end
  end

  defp connect(state) do
    path = path_for(state.mode) <> "?" <> URI.encode_query(query_params(state))

    headers = [
      {"Authorization", "Bearer " <> System.fetch_env!("CARTESIA_API_KEY")},
      {"Cartesia-Version", state.version}
    ]

    uri = URI.parse(state.url)
    {http, ws} = if uri.scheme == "http", do: {:http, :ws}, else: {:https, :wss}

    with {:ok, conn} <- Mint.HTTP.connect(http, uri.host, uri.port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws, conn, path, headers) do
      {:ok, %{state | conn: conn, request_ref: ref}}
    end
  end

  @impl GenServer
  def handle_cast({:push, pcm}, %{websocket: nil} = state),
    do: {:noreply, hold(state, {:binary, pcm})}

  def handle_cast({:push, pcm}, state) do
    case send_frame(state, {:binary, pcm}) do
      {:ok, state} -> {:noreply, state}
      {:error, state, reason} -> {:stop, {:send_failed, reason}, state}
    end
  end

  # PTT release: only the manual socket honors a finalize (bare-text command). No-op on auto.
  # A release during the connect is held behind the audio it ends.
  def handle_cast(:finalize, %{websocket: nil, mode: :manual} = state),
    do: {:noreply, hold(state, {:text, "finalize"})}

  def handle_cast(:finalize, %{websocket: nil} = state), do: {:noreply, state}

  def handle_cast(:finalize, %{mode: :manual} = state) do
    case send_frame(state, {:text, "finalize"}) do
      {:ok, state} -> {:noreply, state}
      {:error, state, reason} -> {:stop, {:send_failed, reason}, state}
    end
  end

  def handle_cast(:finalize, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        responses
        |> Enum.reduce(%{state | conn: conn}, &handle_response/2)
        |> flush_pending()

      # a clean close (session teardown / idle) is expected — stop normally so it doesn't
      # log a crash report or (being linked) take the Conversation down.
      {:error, conn, %Mint.TransportError{reason: :closed}, _responses} ->
        {:stop, :normal, %{state | conn: conn}}

      {:error, conn, reason, _responses} ->
        Logger.warning("Cartesia STT WS error: #{inspect(reason)}")
        {:stop, {:ws_error, reason}, %{state | conn: conn}}

      :unknown ->
        {:noreply, state}
    end
  end

  # ---- upgrade handshake ----
  defp handle_response({:status, ref, status}, %{request_ref: ref} = state),
    do: %{state | status: status}

  defp handle_response({:headers, ref, headers}, %{request_ref: ref} = state),
    do: %{state | resp_headers: headers}

  defp handle_response({:done, ref}, %{request_ref: ref, status: 101} = state) do
    case Mint.WebSocket.new(state.conn, ref, state.status, state.resp_headers) do
      {:ok, conn, websocket} ->
        send(state.owner, :stt_ready)
        %{state | conn: conn, websocket: websocket}

      {:error, conn, reason} ->
        Logger.error("Cartesia STT upgrade failed: #{inspect(reason)}")
        send(state.owner, {:stt_error, reason})
        %{state | conn: conn}
    end
  end

  defp handle_response({:done, ref}, %{request_ref: ref, status: status} = state) do
    Logger.error("Cartesia STT refused upgrade (status #{status})")
    send(state.owner, {:stt_error, {:status, status}})
    state
  end

  # ---- websocket frames ----
  defp handle_response({:data, ref, data}, %{request_ref: ref, websocket: ws} = state)
       when not is_nil(ws) do
    case Mint.WebSocket.decode(ws, data) do
      {:ok, ws, frames} -> Enum.reduce(frames, %{state | websocket: ws}, &handle_frame/2)
      {:error, ws, _reason} -> %{state | websocket: ws}
    end
  end

  defp handle_response(_other, state), do: state

  defp handle_frame({:text, text}, state) do
    {msg, acc} = route(text, state.acc)

    case msg do
      {:stt_error, {:ink, status, detail}} ->
        Logger.warning("[stt] Ink error #{status}: #{detail}")

      _ ->
        :ok
    end

    if msg, do: send(state.owner, msg)
    %{state | acc: acc}
  end

  defp handle_frame(_frame, state), do: state

  # ---- frames held during the connect ----
  defp hold(state, frame) do
    trim(%{
      state
      | pending: :queue.in(frame, state.pending),
        pending_bytes: state.pending_bytes + frame_bytes(frame)
    })
  end

  defp trim(%{pending_bytes: bytes, pending_max_bytes: max} = state) when bytes <= max,
    do: state

  defp trim(state) do
    {{:value, frame}, rest} = :queue.out(state.pending)
    trim(%{state | pending: rest, pending_bytes: state.pending_bytes - frame_bytes(frame)})
  end

  defp frame_bytes({:binary, pcm}), do: byte_size(pcm)
  defp frame_bytes(_text), do: 0

  defp flush_pending(%{websocket: nil} = state), do: {:noreply, state}

  defp flush_pending(state) do
    case :queue.len(state.pending) do
      0 ->
        {:noreply, state}

      n ->
        Logger.info("[stt] socket up; sending #{n} frames held during the connect")
        send_pending(state)
    end
  end

  defp send_pending(state) do
    case :queue.out(state.pending) do
      {:empty, _} ->
        {:noreply, %{state | pending_bytes: 0}}

      {{:value, frame}, rest} ->
        case send_frame(%{state | pending: rest}, frame) do
          {:ok, state} -> send_pending(state)
          {:error, state, reason} -> {:stop, {:send_failed, reason}, state}
        end
    end
  end

  defp send_frame(state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data) do
      {:ok, %{state | conn: conn, websocket: websocket}}
    else
      {:error, websocket_or_conn, reason} ->
        {:error, %{state | websocket: maybe_ws(websocket_or_conn, state)}, reason}
    end
  end

  defp maybe_ws(%Mint.WebSocket{} = ws, _state), do: ws
  defp maybe_ws(_other, state), do: state.websocket

  @doc "Ink-2 endpoint path for the mode: native turns (auto) vs manual finalize (PTT)."
  @spec path_for(:auto | :manual) :: String.t()
  def path_for(:manual), do: "/stt/websocket"
  def path_for(_auto), do: "/stt/turns/websocket"

  @doc """
  Pure transcript router carrying the `{committed, interim}` accumulator. Both endpoints'
  message vocabularies are disjoint, so one router handles both:

    * `turn.update` (auto, cumulative) → `{:stt_partial, transcript}`
    * `turn.end` (auto, final) → `{:stt_endpoint, transcript}`
    * `turn.eager_end` (auto, prediction) → `{:stt_eager_end, transcript}` (acc untouched)
    * `turn.resume` (auto, kept talking) → `{:stt_resume}` (acc untouched)
    * `turn.start` (auto, speech onset) → `{:stt_turn_start}` (acc untouched; barge-in diagnostic)
    * `transcript` is_final=false (manual interim) → preview committed + this
    * `transcript` is_final=true (manual segment) → commit + preview the running total
    * `flush_done` (manual, release ack) → `{:stt_endpoint, whole hold}`
    * `error` (either) → `{:stt_error, {:ink, status_code, "title: message"}}` (acc untouched)

  Returns `{message | nil, acc}`.
  """
  @spec route(String.t(), acc()) :: {tuple() | nil, acc()}
  def route(text, acc) do
    case decode_event(text) do
      {:turn_update, ""} -> {nil, acc}
      {:turn_update, t} -> {{:stt_partial, t}, {[], t}}
      {:turn_end, t} -> emit_endpoint(t)
      {:eager_end, ""} -> {nil, acc}
      {:eager_end, t} -> {{:stt_eager_end, t}, acc}
      :resume -> {{:stt_resume}, acc}
      :turn_start -> {{:stt_turn_start}, acc}
      {:transcript, "", _final?} -> {nil, acc}
      {:transcript, t, false} -> on_interim(t, acc)
      {:transcript, t, true} -> on_commit(t, acc)
      :flush_done -> on_flush(acc)
      {:error, status, detail} -> {{:stt_error, {:ink, status, detail}}, acc}
      :ignore -> {nil, acc}
    end
  end

  # manual interim: preview committed segments + this hypothesis (don't commit)
  defp on_interim(t, {committed, _interim}),
    do: {{:stt_partial, join(committed ++ [t])}, {committed, t}}

  # manual is_final: commit this segment, preview the running total
  defp on_commit(t, {committed, _interim}) do
    segs = committed ++ [t]
    {{:stt_partial, join(segs)}, {segs, ""}}
  end

  # release flush: emit the whole accumulated hold (committed + any trailing interim)
  defp on_flush({committed, interim}), do: emit_endpoint(join(committed ++ [interim]))

  defp emit_endpoint(""), do: {nil, {[], ""}}
  defp emit_endpoint(full), do: {{:stt_endpoint, full}, {[], ""}}

  defp join(parts), do: parts |> Enum.reject(&(&1 == "")) |> Enum.join(" ") |> String.trim()

  defp decode_event(text) do
    case Jason.decode(text) do
      {:ok, %{"type" => "turn.update", "transcript" => t}} when is_binary(t) ->
        {:turn_update, t}

      {:ok, %{"type" => "turn.end", "transcript" => t}} when is_binary(t) ->
        {:turn_end, t}

      {:ok, %{"type" => "turn.eager_end", "transcript" => t}} when is_binary(t) ->
        {:eager_end, t}

      {:ok, %{"type" => "turn.resume"}} ->
        :resume

      {:ok, %{"type" => "turn.start"}} ->
        :turn_start

      {:ok, %{"type" => "transcript", "text" => t} = m} when is_binary(t) ->
        {:transcript, t, m["is_final"] == true}

      {:ok, %{"type" => "flush_done"}} ->
        :flush_done

      {:ok, %{"type" => "error"} = m} ->
        {:error, m["status_code"], Enum.map_join(["title", "message"], ": ", &(m[&1] || "?"))}

      _ ->
        :ignore
    end
  end

  @doc false
  def query_params(state) do
    %{
      model: state.model,
      encoding: "pcm_s16le",
      sample_rate: state.sample_rate
    }
    |> put_turn_end_threshold(state)
  end

  defp put_turn_end_threshold(params, %{mode: :auto, turn_end_threshold: t}) when is_number(t),
    do: Map.put(params, :turn_end_threshold, t)

  defp put_turn_end_threshold(params, _state), do: params
end
