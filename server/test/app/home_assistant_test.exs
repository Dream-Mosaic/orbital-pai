defmodule App.HomeAssistantTest do
  use ExUnit.Case, async: false

  alias App.HomeAssistant

  # async: false — these tests mutate global app env (:home_assistant + req opts).

  # Same seam as test/app/google/calendar_test.exs (:google_req_opts): put the plug in app env,
  # stub per test. Tests call the adapter in-process, so no shared-mode plumbing is needed.
  setup do
    Application.put_env(:app, :home_assistant, %{
      url: "https://ha.example.test",
      token: "test-token"
    })

    Application.put_env(:app, :home_assistant_req_opts, plug: {Req.Test, HaStub})

    on_exit(fn ->
      Application.delete_env(:app, :home_assistant)
      Application.delete_env(:app, :home_assistant_req_opts)
    end)

    :ok
  end

  test "configured? is true with url+token, false without" do
    assert HomeAssistant.configured?()
    Application.delete_env(:app, :home_assistant)
    refute HomeAssistant.configured?()
  end

  test "call_service/3 POSTs the service path with the JSON body (entity_id included)" do
    Req.Test.stub(HaStub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/services/light/turn_on"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"entity_id" => "light.kitchen", "brightness_pct" => 50}
      Req.Test.json(conn, [%{"entity_id" => "light.kitchen", "state" => "on"}])
    end)

    assert {:ok, _} =
             HomeAssistant.call_service("light", "turn_on", %{
               entity_id: "light.kitchen",
               brightness_pct: 50
             })
  end

  test "401 flattens to :unauthorized" do
    Req.Test.stub(HaStub, fn conn -> Plug.Conn.send_resp(conn, 401, "unauthorized") end)

    assert {:error, :unauthorized} =
             HomeAssistant.call_service("light", "turn_on", %{entity_id: "x"})
  end

  test "404 on a service call flattens to :not_found" do
    Req.Test.stub(HaStub, fn conn -> Plug.Conn.send_resp(conn, 404, "not found") end)
    assert {:error, :not_found} = HomeAssistant.call_service("nope", "nothing", %{entity_id: "x"})
  end

  test "an error answer carrying HA's message keeps it: {:http, status, message}" do
    # HA 2026.10+ answers a service that raised with its message (Music Assistant's own words).
    Req.Test.stub(HaStub, fn conn ->
      conn
      |> Plug.Conn.put_status(500)
      |> Req.Test.json(%{"message" => "Could not resolve ['jazz'] to playable media item"})
    end)

    assert {:error, {:http, 500, "Could not resolve ['jazz'] to playable media item"}} =
             HomeAssistant.call_service("music_assistant", "play_media", %{entity_id: "x"})
  end

  test "a bare 500 (older HA's plain-text body, or a blank message) stays {:http, 500}" do
    Req.Test.stub(HaStub, fn conn ->
      Plug.Conn.send_resp(conn, 500, "500 Internal Server Error\n\nServer got itself in trouble")
    end)

    assert {:error, {:http, 500}} =
             HomeAssistant.call_service("music_assistant", "play_media", %{entity_id: "x"})

    Req.Test.stub(HaStub, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => " "})
    end)

    assert {:error, {:http, 500}} =
             HomeAssistant.call_service("music_assistant", "play_media", %{entity_id: "x"})
  end

  test "transport errors flatten to a tagged error, never a raise" do
    Req.Test.stub(HaStub, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error, %Req.TransportError{reason: :timeout}} =
             HomeAssistant.call_service("light", "turn_on", %{entity_id: "x"})
  end

  test "unconfigured → {:error, :not_configured} (defense in depth; tool isn't registered anyway)" do
    Application.delete_env(:app, :home_assistant)

    assert {:error, :not_configured} =
             HomeAssistant.call_service("light", "turn_on", %{entity_id: "x"})
  end
end
