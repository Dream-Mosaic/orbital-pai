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

  No keepalive: unlike Deepgram, Ink has no KeepAlive message. An idle socket clean-closes
  (Ink's ~3-min idle timeout); that stops this process `:normal` and the Conversation
  reconnects on the next mic frame — so an idle PTT gap is recovered, not fatal.
  """

  @behaviour App.Adapters.Stt
  use GenServer
  require Logger

  @host "api.cartesia.ai"
  @port 443

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
    state = %{
      owner: Keyword.fetch!(opts, :owner),
      mode: Keyword.get(opts, :mode, :auto),
      sample_rate: Keyword.get(opts, :sample_rate, 16_000),
      model: Keyword.get(opts, :model, "ink-2"),
      version: Keyword.get(opts, :version, "2026-06-24"),
      conn: nil,
      websocket: nil,
      request_ref: nil,
      status: nil,
      resp_headers: nil,
      # router accumulator: {committed segments, latest interim}
      acc: {[], ""}
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

    with {:ok, conn} <- Mint.HTTP.connect(:https, @host, @port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(:wss, conn, path, headers) do
      {:ok, %{state | conn: conn, request_ref: ref}}
    end
  end

  @impl GenServer
  def handle_cast({:push, _pcm}, %{websocket: nil} = state), do: {:noreply, state}

  def handle_cast({:push, pcm}, state) do
    case send_frame(state, {:binary, pcm}) do
      {:ok, state} -> {:noreply, state}
      {:error, state, reason} -> {:stop, {:send_failed, reason}, state}
    end
  end

  # PTT release: only the manual socket honors a finalize (bare-text command). No-op on auto.
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
        {:noreply, Enum.reduce(responses, %{state | conn: conn}, &handle_response/2)}

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
    if msg, do: send(state.owner, msg)
    %{state | acc: acc}
  end

  defp handle_frame(_frame, state), do: state

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
  end
end
