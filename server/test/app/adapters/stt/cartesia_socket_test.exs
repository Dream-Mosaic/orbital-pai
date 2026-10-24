defmodule App.Adapters.Stt.CartesiaSocketTest do
  @moduledoc """
  `App.Adapters.Stt.Cartesia` against a local fake Ink-2 (Bandit + WebSock on a loopback
  port), over the real Mint.WebSocket path. The fake holds the 101 for a while, the way a
  cold connect to Cartesia does, so frames pushed before the socket is up are exercised.
  """
  use ExUnit.Case, async: false

  alias App.Adapters.Stt.Cartesia

  defmodule FakeInk do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init(st), do: {:ok, st}

    @impl true
    def handle_in({data, opcode: opcode}, st) do
      send(st.test, {:fake_ink, opcode, data})
      {:ok, st}
    end

    @impl true
    def handle_info(_msg, st), do: {:ok, st}

    @impl true
    def terminate(_reason, _st), do: :ok
  end

  defmodule FakePlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(%{request_path: "/stt/" <> _} = conn, st) do
      send(st.test, {:fake_ink_upgrade, conn.request_path, URI.decode_query(conn.query_string)})
      Process.sleep(st.delay_ms)
      conn |> WebSockAdapter.upgrade(FakeInk, st, timeout: 60_000) |> halt()
    end

    def call(conn, _st), do: conn |> send_resp(404, "not found") |> halt()
  end

  setup do
    previous = System.get_env("CARTESIA_API_KEY")
    System.put_env("CARTESIA_API_KEY", "test-key-not-a-secret")

    on_exit(fn ->
      if previous,
        do: System.put_env("CARTESIA_API_KEY", previous),
        else: System.delete_env("CARTESIA_API_KEY")
    end)

    {:ok, server} =
      start_supervised(
        {Bandit,
         plug: {FakePlug, %{test: self(), delay_ms: 300}},
         port: 0,
         ip: :loopback,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{url: "http://127.0.0.1:#{port}"}
  end

  defp start_stt(url, opts \\ []) do
    {:ok, pid} = Cartesia.start_link([owner: self(), url: url] ++ opts)
    pid
  end

  defp frames(n), do: for(i <- 1..n, do: :binary.copy(<<i>>, 640))

  test "audio pushed while the socket connects arrives, in order, once it is up", %{url: url} do
    pid = start_stt(url)
    [a, b, c, d] = frames(4)

    # a wake after Ink's idle close: the pre-roll and first words land before the 101
    Cartesia.push(pid, a)
    Cartesia.push(pid, b)
    Cartesia.push(pid, c)

    assert_receive :stt_ready, 2_000
    Cartesia.push(pid, d)

    for frame <- [a, b, c, d], do: assert_receive({:fake_ink, :binary, ^frame}, 1_000)
  end

  test "a PTT release during the connect is sent after the held audio", %{url: url} do
    pid = start_stt(url, mode: :manual)
    [a, b] = frames(2)

    Cartesia.push(pid, a)
    Cartesia.push(pid, b)
    Cartesia.finalize(pid)

    assert_receive :stt_ready, 2_000
    assert_receive {:fake_ink, :binary, ^a}, 1_000
    assert_receive {:fake_ink, :binary, ^b}, 1_000
    assert_receive {:fake_ink, :text, "finalize"}, 1_000
  end

  test "the hold is bounded: past the cap the oldest audio goes first", %{url: url} do
    pid = start_stt(url, pending_max_bytes: 1_280)
    [a, b, c] = frames(3)

    Cartesia.push(pid, a)
    Cartesia.push(pid, b)
    Cartesia.push(pid, c)

    assert_receive :stt_ready, 2_000
    assert_receive {:fake_ink, :binary, ^b}, 1_000
    assert_receive {:fake_ink, :binary, ^c}, 1_000
    refute_received {:fake_ink, :binary, ^a}
  end

  test "the hands-free socket asks Ink for the configured turn-end threshold", %{url: url} do
    start_stt(url, mode: :auto, turn_end_threshold: 0.1)

    assert_receive {:fake_ink_upgrade, "/stt/turns/websocket", query}, 2_000
    assert query["turn_end_threshold"] == "0.1"
    assert query["model"] == "ink-2"
  end

  test "the PTT socket is opened without turn parameters", %{url: url} do
    start_stt(url, mode: :manual, turn_end_threshold: 0.1)

    assert_receive {:fake_ink_upgrade, "/stt/websocket", query}, 2_000
    refute Map.has_key?(query, "turn_end_threshold")
  end
end
