defmodule App.Dispatch.NtfyTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias App.Dispatch.Ntfy

  @msg %{
    title: "PR ready: chronicles #31",
    message: "Added the thing",
    click: "https://forge.test/pr/1",
    tags: "white_check_mark",
    priority: "default"
  }

  setup do
    Application.put_env(:app, :ntfy, %{url: "https://ntfy.test/", topic: "henry", token: nil})
    Application.put_env(:app, :ntfy_req_opts, plug: {Req.Test, NtfyStub})

    on_exit(fn ->
      Application.delete_env(:app, :ntfy)
      Application.delete_env(:app, :ntfy_req_opts)
    end)
  end

  test "posts the message body to url/topic with the headers" do
    Req.Test.stub(NtfyStub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert conn.method == "POST"
      assert conn.request_path == "/henry"
      assert body == "Added the thing"
      assert Plug.Conn.get_req_header(conn, "title") == ["PR ready: chronicles #31"]
      assert Plug.Conn.get_req_header(conn, "click") == ["https://forge.test/pr/1"]
      assert Plug.Conn.get_req_header(conn, "tags") == ["white_check_mark"]
      assert Plug.Conn.get_req_header(conn, "priority") == ["default"]
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      Plug.Conn.send_resp(conn, 200, "{}")
    end)

    assert :ok = Ntfy.publish(@msg)
  end

  test "sends a bearer token only when configured" do
    Application.put_env(:app, :ntfy, %{url: "https://ntfy.test", topic: "henry", token: "tk_s3"})

    Req.Test.stub(NtfyStub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tk_s3"]
      Plug.Conn.send_resp(conn, 200, "{}")
    end)

    assert :ok = Ntfy.publish(@msg)
  end

  test "a 500 is an error, logged once, without the token, and not retried" do
    Application.put_env(:app, :ntfy, %{url: "https://ntfy.test", topic: "henry", token: "tk_s3"})
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(NtfyStub, fn conn ->
      Agent.update(calls, &(&1 + 1))
      Plug.Conn.send_resp(conn, 500, "boom")
    end)

    log = capture_log(fn -> assert {:error, {:http, 500}} = Ntfy.publish(@msg) end)
    assert Agent.get(calls, & &1) == 1
    assert log =~ "500"
    refute log =~ "tk_s3"
  end

  test "unconfigured is an error" do
    Application.delete_env(:app, :ntfy)
    assert {:error, :not_configured} = Ntfy.publish(@msg)
  end

  test "a Click with control characters is omitted" do
    Req.Test.stub(NtfyStub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "click") == []
      assert Plug.Conn.get_req_header(conn, "title") == ["PR ready: chronicles #31"]
      Plug.Conn.send_resp(conn, 200, "{}")
    end)

    assert :ok = Ntfy.publish(%{@msg | click: "https://x.test/a\r\nX-Evil: 1"})
  end
end
