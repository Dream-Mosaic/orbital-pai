defmodule App.HomeAssistant.LiveTest do
  @moduledoc """
  `App.HomeAssistant.Live` against a local fake Home Assistant (Bandit + WebSock on a random
  loopback port): the real Mint.WebSocket path end to end — upgrade, auth, the five loads,
  state events, WebSocket pings, a dropped connection and the reconnect, a refused token, and a
  socket that goes silent. No real HA is ever reached.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias App.HomeAssistant.{Directory, Live}
  alias App.Test.HomeFixture

  @token "test-token-not-a-secret"

  defmodule FakeHA do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init(%{test: test} = st) do
      send(test, {:fake_ha, :connected, self()})
      {:push, {:text, Jason.encode!(%{type: "auth_required", ha_version: "2026.8.0"})}, st}
    end

    @impl true
    def handle_in({text, opcode: :text}, st) do
      msg = Jason.decode!(text)
      send(st.test, {:fake_ha, :in, msg})

      case reply(msg, st) do
        [] -> {:ok, st}
        frames -> {:push, frames, st}
      end
    end

    @impl true
    def handle_control({data, opcode: :pong}, st) do
      send(st.test, {:fake_ha, :pong, data})
      {:ok, st}
    end

    def handle_control(_other, st), do: {:ok, st}

    @impl true
    def handle_info({:push, frames}, st), do: {:push, frames, st}
    def handle_info(:close, st), do: {:stop, :normal, st}

    @impl true
    def terminate(_reason, _st), do: :ok

    defp reply(_msg, %{mode: :mute}), do: []

    defp reply(%{"type" => "auth", "access_token" => token}, st) do
      if token == st.token,
        do: [json(%{type: "auth_ok", ha_version: "2026.8.0"})],
        else: [json(%{type: "auth_invalid", message: "Invalid access token or password"})]
    end

    defp reply(%{"id" => id, "type" => "ping"}, _st), do: [json(%{id: id, type: "pong"})]

    defp reply(%{"id" => id, "type" => type}, _st),
      do: [json(%{id: id, type: "result", success: true, result: payload(type)})]

    defp payload("config/area_registry/list"), do: HomeFixture.payloads().areas
    defp payload("config/device_registry/list"), do: HomeFixture.payloads().devices
    defp payload("config/entity_registry/list"), do: HomeFixture.payloads().entities

    defp payload("homeassistant/expose_entity/list"),
      do: %{exposed_entities: HomeFixture.payloads().exposed}

    defp payload("get_states"), do: HomeFixture.payloads().states
    defp payload(_subscribe_events), do: nil

    defp json(map), do: {:text, Jason.encode!(map)}
  end

  defmodule FakePlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(%{request_path: "/api/websocket"} = conn, st),
      do: conn |> WebSockAdapter.upgrade(FakeHA, st, timeout: 60_000) |> halt()

    def call(conn, _st), do: conn |> send_resp(404, "not found") |> halt()
  end

  defp start_fake_ha(opts \\ []) do
    st = %{test: self(), token: @token, mode: Keyword.get(opts, :mode, :normal)}

    {:ok, server} =
      start_supervised(
        {Bandit, plug: {FakePlug, st}, port: 0, ip: :loopback, startup_log: false},
        id: :fake_ha
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}"
  end

  defp start_live(url, opts \\ []) do
    config = %{url: url, token: Keyword.get(opts, :token, @token)}
    Application.put_env(:app, :home_assistant, config)
    start_supervised!({Live, [config: config] ++ opts})
  end

  setup do
    prev = Application.get_env(:app, :home_assistant)
    Application.delete_env(:app, :home_assistant_directory)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:app, :home_assistant, prev),
        else: Application.delete_env(:app, :home_assistant)
    end)
  end

  defp eventually(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline, do: flunk("condition never held")
        Process.sleep(20)
        poll(fun, deadline)

      value ->
        value
    end
  end

  defp loaded_dir do
    eventually(fn ->
      case App.HomeAssistant.directory() do
        {:ok, %Directory{connected?: true} = dir} -> dir
        _ -> nil
      end
    end)
  end

  @tag capture_log: true
  test "loads the house over the socket, follows state events, answers pings, survives a drop" do
    url = start_fake_ha()
    start_live(url)

    assert_receive {:fake_ha, :connected, ha}, 2_000
    assert_receive {:fake_ha, :in, %{"type" => "auth", "access_token" => @token}}, 2_000

    dir = loaded_dir()
    assert Directory.get(dir, "light.gaming_room_lights")
    assert dir.exposure_known?

    # a state event flows into the directory
    assert_receive {:fake_ha, :in,
                    %{"type" => "subscribe_events", "event_type" => "state_changed", "id" => sid}}

    new_state = %{
      "entity_id" => "switch.fireplace_switch",
      "state" => "on",
      "attributes" => %{"friendly_name" => "Fireplace Switch"}
    }

    send(
      ha,
      {:push,
       {:text,
        Jason.encode!(%{
          id: sid,
          type: "event",
          event: %{
            event_type: "state_changed",
            data: %{entity_id: "switch.fireplace_switch", new_state: new_state}
          }
        })}}
    )

    eventually(fn ->
      {:ok, d} = App.HomeAssistant.directory()
      Directory.state(d, "switch.fireplace_switch")["state"] == "on"
    end)

    # a WebSocket ping is answered with the same payload
    send(ha, {:push, {:ping, "hb-1"}})
    assert_receive {:fake_ha, :pong, "hb-1"}, 2_000

    # the connection drops: last-known directory stays readable, marked disconnected
    log =
      capture_log(fn ->
        send(ha, :close)

        eventually(fn ->
          match?({:ok, %Directory{connected?: false}}, App.HomeAssistant.directory())
        end)
      end)

    assert log =~ ~r/\[home\] socket down: closed by Home Assistant \(1000\); retry in 1s/
    {:ok, stale} = App.HomeAssistant.directory()
    assert Directory.state(stale, "switch.fireplace_switch")["state"] == "on"
    assert %DateTime{} = stale.disconnected_at

    # ...and it reconnects and reloads by itself
    assert_receive {:fake_ha, :connected, ha2}, 4_000
    assert ha2 != ha
    assert Directory.get(loaded_dir(), "switch.fireplace_switch")
  end

  test "a refused token waits ten minutes and never logs the token" do
    url = start_fake_ha()

    log =
      capture_log(fn ->
        start_live(url, token: "sekrit-wrong-token")
        assert_receive {:fake_ha, :connected, ha}, 2_000
        assert_receive {:fake_ha, :in, %{"type" => "auth"}}, 2_000
        # real HA closes the socket after auth_invalid
        Process.sleep(100)
        send(ha, :close)
        Process.sleep(300)
      end)

    assert log =~ "[home] socket auth refused — HOME_ASSISTANT_TOKEN needs attention"
    assert log =~ ~r/\[home\] socket down: .*; retry in 600s/
    refute log =~ "sekrit-wrong-token"
    assert {:error, :not_loaded} = App.HomeAssistant.directory()
    # the raw term, not inspect/1 (the struct's derived Inspect already hides it there)
    assert :binary.match(:erlang.term_to_binary(:sys.get_status(Live)), "sekrit-wrong-token") ==
             :nomatch
  end

  test "a host that refuses the connection backs off and never blocks a read" do
    log =
      capture_log(fn ->
        start_live("http://127.0.0.1:1")
        assert {:error, :not_loaded} = App.HomeAssistant.directory()
        Process.sleep(300)
      end)

    assert log =~ ~r/\[home\] socket down: .*; retry in 1s/
  end

  test "a wrong path is an upgrade refusal, not a crash" do
    url = start_fake_ha()

    log =
      capture_log(fn ->
        start_live(url <> "/not-ha")
        Process.sleep(300)
      end)

    assert log =~ "[home] socket down: upgrade refused (HTTP 404); retry in 1s"
  end

  test "a socket that goes silent is declared dead" do
    url = start_fake_ha(mode: :mute)

    log =
      capture_log(fn ->
        start_live(url, heartbeat_ms: 30, ping_after_ms: 50, stale_after_ms: 150)
        assert_receive {:fake_ha, :connected, _}, 2_000
        Process.sleep(400)
      end)

    assert log =~ ~r/\[home\] socket down: silent for \d+s; retry in 1s/
  end

  # A raw TCP "HA" that controls packet boundaries: the 101 and `auth_required` leave in ONE
  # write (Mint then surfaces the frame bytes before `:done`), and get_states goes out as three
  # fragments split across writes.
  test "a first frame riding in the 101's packet, and a fragmented get_states, both land" do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    start_live("http://127.0.0.1:#{port}")

    sock = raw_upgrade(listen)

    {ws, [auth]} = recv_msgs(sock, %Mint.WebSocket{}, 1)
    assert auth["type"] == "auth"
    :ok = :gen_tcp.send(sock, text_frame(%{type: "auth_ok", ha_version: "2026.8.0"}))

    {_ws, cmds} = recv_msgs(sock, ws, 10)

    for %{"id" => id, "type" => type} <- cmds do
      body = Jason.encode!(%{id: id, type: "result", success: true, result: raw_payload(type)})

      if type == "get_states" do
        third = div(byte_size(body), 3)
        <<a::binary-size(third), b::binary-size(third), c::binary>> = body
        :ok = :gen_tcp.send(sock, server_frame(0, 0x1, a))
        :ok = :gen_tcp.send(sock, server_frame(0, 0x0, b))
        :ok = :gen_tcp.send(sock, server_frame(1, 0x0, c))
      else
        :ok = :gen_tcp.send(sock, server_frame(1, 0x1, body))
      end
    end

    assert Directory.get(loaded_dir(), "light.gaming_room_lights")
    :gen_tcp.close(sock)
    :gen_tcp.close(listen)
  end

  # The window between the connect task's handoff and Live learning the conn: the 101 and
  # auth_required are guaranteed to arrive while the task still owns the socket (it sleeps
  # before handing over). An active-mode socket would deliver them to the task, Mint would
  # forward them to Live ahead of the task's reply, and Live would drop them as strays.
  test "data that arrives before the conn is handed over is not lost" do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    start_live("http://127.0.0.1:#{port}", handoff_delay_ms: 300)

    sock = raw_upgrade(listen)
    {_ws, [auth]} = recv_msgs(sock, %Mint.WebSocket{}, 1)
    assert auth["type"] == "auth"
    :gen_tcp.close(sock)
    :gen_tcp.close(listen)
  end

  # Accept one client, answer its upgrade with the 101 AND auth_required in a single write.
  defp raw_upgrade(listen) do
    {:ok, sock} = :gen_tcp.accept(listen, 2_000)
    request = recv_until(sock, "", "\r\n\r\n")
    [_, key] = Regex.run(~r/sec-websocket-key: *(\S+)/i, request)
    accept = :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()

    :ok =
      :gen_tcp.send(
        sock,
        "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\n" <>
          "sec-websocket-accept: #{accept}\r\n\r\n" <>
          text_frame(%{type: "auth_required", ha_version: "2026.8.0"})
      )

    sock
  end

  defp raw_payload("config/area_registry/list"), do: HomeFixture.payloads().areas
  defp raw_payload("config/device_registry/list"), do: HomeFixture.payloads().devices
  defp raw_payload("config/entity_registry/list"), do: HomeFixture.payloads().entities

  defp raw_payload("homeassistant/expose_entity/list"),
    do: %{exposed_entities: HomeFixture.payloads().exposed}

  defp raw_payload("get_states"), do: HomeFixture.payloads().states
  defp raw_payload(_subscribe_events), do: nil

  defp text_frame(map), do: server_frame(1, 0x1, Jason.encode!(map))

  defp recv_until(sock, acc, marker) do
    if String.contains?(acc, marker) do
      acc
    else
      {:ok, data} = :gen_tcp.recv(sock, 0, 2_000)
      recv_until(sock, acc <> data, marker)
    end
  end

  # Decode the client's (masked) frames until `n` JSON messages have arrived.
  defp recv_msgs(sock, ws, n, acc \\ []) do
    if length(acc) >= n do
      {ws, acc}
    else
      {:ok, data} = :gen_tcp.recv(sock, 0, 2_000)
      {:ok, ws, frames} = Mint.WebSocket.decode(ws, data)
      msgs = for {:text, t} <- frames, do: Jason.decode!(t)
      recv_msgs(sock, ws, n, acc ++ msgs)
    end
  end

  test "Mint reassembles a fragmented message and partial reads into one text frame" do
    # Pins the behaviour Live relies on (see its moduledoc): continuation frames and split TCP
    # reads never surface — only the whole `{:text, json}`.
    payload =
      Jason.encode!(%{
        id: 5,
        type: "result",
        success: true,
        result: String.duplicate("x", 300_000)
      })

    <<a::binary-size(100_000), b::binary-size(100_000), c::binary>> = payload

    wire =
      server_frame(0, 0x1, a) <> server_frame(0, 0x0, b) <> server_frame(1, 0x0, c)

    chunks = for <<chunk::binary-size(16_384) <- wire>>, do: chunk
    tail = binary_part(wire, length(chunks) * 16_384, byte_size(wire) - length(chunks) * 16_384)

    {_ws, frames} =
      Enum.reduce(chunks ++ [tail], {%Mint.WebSocket{}, []}, fn data, {ws, acc} ->
        {:ok, ws, frames} = Mint.WebSocket.decode(ws, data)
        {ws, acc ++ frames}
      end)

    assert frames == [{:text, payload}]
  end

  # An unmasked server→client frame with a 64-bit length.
  defp server_frame(fin, opcode, data),
    do: <<fin::1, 0::3, opcode::4, 0::1, 127::7, byte_size(data)::64, data::binary>>
end
