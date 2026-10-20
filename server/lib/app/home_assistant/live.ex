defmodule App.HomeAssistant.Live do
  @moduledoc """
  Holds the one Home Assistant WebSocket (`<url>/api/websocket`, the same URL + long-lived
  token as the REST writes) and keeps `App.HomeAssistant.Directory` live (spec §2.1). Read by
  `App.HomeAssistant.directory/0` via `GenServer.call(__MODULE__, :directory)`.

  Deliberately thin: every protocol decision lives in the pure `App.HomeAssistant.Socket`.
  This process only connects, shuttles frames, answers WebSocket pings, and runs three timers:

    * **reconnect** with backoff (`Socket.retry_delay_s/2`: 1, 2, 5, 15, 30, 60 s; 10 min after
      a refused token). A drop keeps the last directory, marked disconnected, so names still
      resolve and status answers can say "as of".
    * **backstop** — `Socket.refresh/1` every 10 min (registries + exposure).
    * **heartbeat** — a quiet socket gets an app-level `ping`; one silent for 75 s is treated as
      dead (a vanished network path never delivers a FIN, and a stale directory would claim to
      be connected forever).

  The TCP/TLS connect + upgrade request run in a task and the conn is handed back, so a slow
  or black-holed host never blocks a `:directory` read behind it. The task connects in
  **passive** mode and this process switches the conn to active only once it holds it: in
  active mode, anything HA sent before the handoff (the 101, `auth_required`) would be
  delivered to the task, forwarded here AHEAD of the task's reply, and dropped as a stray —
  and with `active: :once` the socket would then go quiet until the heartbeat gave up.

  Fragmentation: `Mint.WebSocket.decode/2` reassembles fragmented messages itself (partial
  fragments wait in the websocket's `fragment`, partial TCP reads in its `buffer`) and only
  ever emits the whole `{:text, json}` — `get_states` (~1 MB) arrives as one message here.

  Never logs the token or the auth message; `format_status/1` redacts it from crash reports.
  Started only when HA is configured and `:start_home_assistant_live` (default true; false in
  test) — see `App.Application`.
  """

  use GenServer
  require Logger

  alias App.HomeAssistant.Socket

  @backstop_ms :timer.minutes(10)
  @heartbeat_ms 30_000
  @ping_after_ms 25_000
  @stale_after_ms 75_000
  @connect_timeout_ms 10_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # -- GenServer --

  @impl true
  def init(opts) do
    case Keyword.get_lazy(opts, :config, fn -> Application.get_env(:app, :home_assistant) end) do
      %{url: url, token: token}
      when is_binary(url) and url != "" and is_binary(token) and token != "" ->
        timing = %{
          backstop: Keyword.get(opts, :backstop_ms, @backstop_ms),
          heartbeat: Keyword.get(opts, :heartbeat_ms, @heartbeat_ms),
          ping_after: Keyword.get(opts, :ping_after_ms, @ping_after_ms),
          stale_after: Keyword.get(opts, :stale_after_ms, @stale_after_ms),
          # test seam: hold the socket in the connect task this long before handing it over
          handoff_delay: Keyword.get(opts, :handoff_delay_ms, 0)
        }

        Process.send_after(self(), :backstop, timing.backstop)
        Process.send_after(self(), :heartbeat, timing.heartbeat)

        state = %{
          target: target(url),
          timing: timing,
          socket: Socket.new(token),
          conn: nil,
          websocket: nil,
          ref: nil,
          status: nil,
          headers: nil,
          # frame bytes that rode in with the 101 response, before the websocket existed
          early: "",
          connecting: nil,
          retry: nil,
          attempt: 0,
          last_in: nil
        }

        {:ok, state, {:continue, :connect}}

      _ ->
        :ignore
    end
  end

  @impl true
  def handle_continue(:connect, s), do: {:noreply, connect(s)}

  @impl true
  def handle_call(:directory, _from, s) do
    reply =
      case Socket.directory(s.socket) do
        nil -> {:error, :not_loaded}
        dir -> {:ok, dir}
      end

    {:reply, reply, s}
  end

  @impl true
  def handle_info(:connect, s), do: {:noreply, connect(%{s | retry: nil})}

  # The connect task's answer: the (passive) conn, now owned by this process, or why it failed.
  # Only now does the socket start delivering, so nothing that arrived earlier is lost.
  def handle_info({ref, result}, %{connecting: ref} = s) do
    Process.demonitor(ref, [:flush])
    s = %{s | connecting: nil}

    case result do
      {:ok, conn, req_ref} ->
        case Mint.HTTP.set_mode(conn, :active) do
          {:ok, conn} -> {:noreply, %{s | conn: conn, ref: req_ref, last_in: now_ms()}}
          {:error, reason} -> {:noreply, down(%{s | conn: conn}, reason)}
        end

      {:error, reason} ->
        {:noreply, down(s, reason)}
    end
  end

  def handle_info(:backstop, s) do
    Process.send_after(self(), :backstop, s.timing.backstop)
    {socket, out} = Socket.refresh(s.socket)
    {:noreply, settle(send_messages(%{s | socket: socket}, out))}
  end

  def handle_info(:heartbeat, s) do
    Process.send_after(self(), :heartbeat, s.timing.heartbeat)
    idle = s.last_in && now_ms() - s.last_in

    cond do
      is_nil(s.conn) or is_nil(idle) ->
        {:noreply, s}

      idle >= s.timing.stale_after ->
        {:noreply, down(s, {:silent, idle})}

      idle >= s.timing.ping_after ->
        {socket, out} = Socket.ping(s.socket)
        {:noreply, settle(send_messages(%{s | socket: socket}, out))}

      true ->
        {:noreply, s}
    end
  end

  def handle_info(message, %{conn: conn} = s) when not is_nil(conn) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        {:noreply, settle(responses(responses, %{s | conn: conn, last_in: now_ms()}))}

      {:error, conn, reason, _responses} ->
        {:noreply, down(%{s | conn: conn}, reason)}

      :unknown ->
        {:noreply, s}
    end
  end

  # Stray socket messages from a connection already torn down.
  def handle_info(_message, s), do: {:noreply, s}

  @impl true
  def format_status(%{state: %{socket: %Socket{} = socket} = state} = status),
    do: %{status | state: %{state | socket: %{socket | token: "[redacted]"}}}

  def format_status(status), do: status

  # -- connecting --

  defp connect(%{connecting: nil, conn: nil} = s) do
    target = s.target
    delay = s.timing.handoff_delay
    owner = self()
    %{s | connecting: Task.async(fn -> open(target, owner, delay) end).ref}
  end

  defp connect(s), do: s

  # Runs in the task. Passive: the socket delivers nothing until the owner activates it.
  defp open(%{http: http, ws: ws, host: host, port: port, path: path}, owner, delay) do
    opts = [
      protocols: [:http1],
      mode: :passive,
      transport_opts: [timeout: @connect_timeout_ms]
    ]

    with {:ok, conn} <- Mint.HTTP.connect(http, host, port, opts),
         {:ok, conn, ref} <- upgrade(ws, conn, path),
         :ok <- if(delay > 0, do: Process.sleep(delay), else: :ok),
         {:ok, conn} <- Mint.HTTP.controlling_process(conn, owner) do
      {:ok, conn, ref}
    end
  rescue
    e -> {:error, e}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp upgrade(ws, conn, path) do
    case Mint.WebSocket.upgrade(ws, conn, path, []) do
      {:ok, _conn, _ref} = ok ->
        ok

      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        {:error, reason}
    end
  end

  @doc false
  def target(url) do
    uri = URI.parse(url)
    {http, ws} = if uri.scheme == "https", do: {:https, :wss}, else: {:http, :ws}
    path = String.trim_trailing(uri.path || "", "/") <> "/api/websocket"
    %{http: http, ws: ws, host: uri.host, port: uri.port, path: path}
  end

  # -- inbound: {:ok, s} | {:down, s, reason} --

  defp responses([], s), do: {:ok, s}

  defp responses([r | rest], s) do
    case response(r, s) do
      {:ok, s} -> responses(rest, s)
      down -> down
    end
  end

  defp response({:status, ref, status}, %{ref: ref} = s), do: {:ok, %{s | status: status}}
  defp response({:headers, ref, headers}, %{ref: ref} = s), do: {:ok, %{s | headers: headers}}

  # HA pushes `auth_required` the moment the handshake completes. When it shares a packet with
  # the 101, Mint's HTTP/1 parser hands those bytes over as `{:data, ref, _}` BEFORE `{:done,
  # ref}` — before the websocket exists. Hold them and decode them once it does, or the
  # handshake silently stalls.
  defp response({:data, ref, data}, %{ref: ref, websocket: nil, status: 101} = s),
    do: {:ok, %{s | early: s.early <> data}}

  defp response({:done, ref}, %{ref: ref, websocket: nil, status: 101} = s) do
    case Mint.WebSocket.new(s.conn, ref, s.status, s.headers) do
      {:ok, conn, websocket} ->
        {early, s} = {s.early, %{s | conn: conn, websocket: websocket, early: ""}}
        if early == "", do: {:ok, s}, else: response({:data, ref, early}, s)

      {:error, conn, reason} ->
        {:down, %{s | conn: conn}, reason}
    end
  end

  defp response({:done, ref}, %{ref: ref, websocket: nil} = s),
    do: {:down, s, {:upgrade_refused, s.status}}

  defp response({:data, ref, data}, %{ref: ref, websocket: ws} = s) when not is_nil(ws) do
    case Mint.WebSocket.decode(ws, data) do
      {:ok, ws, frames} -> frames(frames, %{s | websocket: ws})
      {:error, ws, reason} -> {:down, %{s | websocket: ws}, reason}
    end
  end

  defp response({:error, ref, reason}, %{ref: ref} = s), do: {:down, s, reason}
  defp response(_other, s), do: {:ok, s}

  defp frames([], s), do: {:ok, s}

  defp frames([f | rest], s) do
    case frame(f, s) do
      {:ok, s} -> frames(rest, s)
      down -> down
    end
  end

  defp frame({:text, text}, s) do
    case Jason.decode(text) do
      {:ok, msg} when is_map(msg) ->
        inbound(msg, s)

      _ ->
        Logger.debug("[home] ignored a non-JSON-object frame (#{byte_size(text)} bytes)")
        {:ok, s}
    end
  end

  defp frame({:ping, data}, s), do: send_frames(s, [{:pong, data}])
  defp frame({:close, code, _reason}, s), do: {:down, s, {:closed, code}}
  # A broken frame may be a lost result (e.g. get_states): reconnect rather than stall.
  defp frame({:error, reason}, s), do: {:down, s, {:bad_frame, reason}}
  defp frame(_pong_or_binary, s), do: {:ok, s}

  # A crash in the handling must not crash-loop this optional child (too many restarts would
  # take the application supervisor with it): treat it as a dropped connection.
  defp inbound(msg, s) do
    case safe_handle(s.socket, msg) do
      {:ok, {socket, out}} ->
        s = %{s | socket: socket}
        s = if socket.phase == :ready, do: %{s | attempt: 0}, else: s
        send_messages(s, out)

      {:error, module} ->
        {:down, s, {:crashed, module}}
    end
  end

  # Only the pure decision is rescued (its data is HA's, never the token's).
  defp safe_handle(socket, msg) do
    {:ok, Socket.handle(socket, msg, DateTime.utc_now())}
  rescue
    e ->
      Logger.error(
        "[home] socket message handling crashed: #{String.slice(Exception.message(e), 0, 300)}"
      )

      {:error, e.__struct__}
  end

  # -- outbound --

  # Non-raising encode: the auth frame carries the token, and an encode error's message would
  # quote the offending value.
  defp send_messages(s, []), do: {:ok, s}

  defp send_messages(s, msgs) do
    Enum.reduce_while(msgs, {:ok, []}, fn msg, {:ok, acc} ->
      case Jason.encode(msg) do
        {:ok, json} -> {:cont, {:ok, [{:text, json} | acc]}}
        {:error, _} -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, frames} -> send_frames(s, Enum.reverse(frames))
      :error -> {:down, s, :unencodable_message}
    end
  end

  defp send_frames(%{websocket: nil} = s, _frames), do: {:ok, s}

  defp send_frames(s, frames) do
    Enum.reduce_while(frames, {:ok, s}, fn frame, {:ok, s} ->
      with {:ok, ws, data} <- Mint.WebSocket.encode(s.websocket, frame),
           {:ok, conn} <- Mint.WebSocket.stream_request_body(s.conn, s.ref, data) do
        {:cont, {:ok, %{s | websocket: ws, conn: conn}}}
      else
        {:error, %Mint.WebSocket{} = ws, reason} -> {:halt, {:down, %{s | websocket: ws}, reason}}
        {:error, conn, reason} -> {:halt, {:down, %{s | conn: conn}, reason}}
      end
    end)
  end

  # -- going down --

  defp settle({:ok, s}), do: s
  defp settle({:down, s, reason}), do: down(s, reason)

  defp down(s, reason) do
    if s.conn, do: Mint.HTTP.close(s.conn)
    if s.retry, do: Process.cancel_timer(s.retry)
    delay_s = Socket.retry_delay_s(s.socket, s.attempt)
    Logger.warning("[home] socket down: #{describe(reason)}; retry in #{delay_s}s")

    %{
      s
      | socket: Socket.disconnected(s.socket, DateTime.utc_now()),
        conn: nil,
        websocket: nil,
        ref: nil,
        status: nil,
        headers: nil,
        early: "",
        last_in: nil,
        attempt: s.attempt + 1,
        retry: Process.send_after(self(), :connect, delay_s * 1_000)
    }
  end

  defp describe(%{__exception__: true} = e), do: Exception.message(e)
  defp describe({:closed, code}), do: "closed by Home Assistant (#{code})"
  defp describe({:upgrade_refused, status}), do: "upgrade refused (HTTP #{status})"
  defp describe({:silent, ms}), do: "silent for #{div(ms, 1_000)}s"
  defp describe({:crashed, module}), do: "message handling crashed (#{inspect(module)})"
  defp describe(other), do: inspect(other, limit: 5, printable_limit: 120)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
