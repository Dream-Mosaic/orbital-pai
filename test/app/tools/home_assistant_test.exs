defmodule App.Tools.HomeAssistantTest do
  use ExUnit.Case, async: false

  alias App.Tools.HomeAssistant, as: Tool

  # async: false — mutates global app env (:home_assistant + req opts).

  @ctx %{session_id: "test", config: App.Config.default()}

  setup do
    Application.put_env(:app, :home_assistant, %{
      url: "https://ha.example.test",
      token: "test-token"
    })

    Application.put_env(:app, :home_assistant_req_opts, plug: {Req.Test, HaToolStub})

    on_exit(fn ->
      Application.delete_env(:app, :home_assistant)
      Application.delete_env(:app, :home_assistant_req_opts)
    end)

    :ok
  end

  defp stub_states(entities) do
    Req.Test.stub(HaToolStub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/states"} -> Req.Test.json(conn, entities)
        other -> flunk("unexpected request: #{inspect(other)}")
      end
    end)
  end

  @raw [
    %{
      "entity_id" => "light.kitchen",
      "state" => "on",
      "attributes" => %{"friendly_name" => "Kitchen Light", "brightness" => 255}
    },
    %{
      "entity_id" => "lock.front_door",
      "state" => "locked",
      "attributes" => %{"friendly_name" => "Front Door"}
    },
    %{"entity_id" => "sun.sun", "state" => "above_horizon", "attributes" => %{}}
  ]

  test "declarations include home_state with an optional query" do
    decls = Tool.declarations()
    hs = Enum.find(decls, &(&1.name == "home_state"))
    assert hs
    assert hs.parameters.required == []
    assert Map.has_key?(hs.parameters.properties, :query)
  end

  test "home_state returns the compacted view (noise dropped, sensitive included)" do
    stub_states(@raw)

    assert {:ok, %{entities: entities, count: 2}} = Tool.execute("home_state", %{}, @ctx)
    assert Enum.map(entities, & &1.entity_id) == ["light.kitchen", "lock.front_door"]
    assert %{name: "Kitchen Light", brightness_pct: 100} = hd(entities)
  end

  test "home_state applies the query filter and notes an empty result" do
    stub_states(@raw)

    assert {:ok, %{entities: [%{entity_id: "light.kitchen"}], count: 1}} =
             Tool.execute("home_state", %{"query" => "kitchen"}, @ctx)

    assert {:ok, %{entities: [], note: note}} =
             Tool.execute("home_state", %{"query" => "sauna"}, @ctx)

    assert note =~ "no matching"
  end

  test "home_state flattens an unreachable hub to a relayable error note" do
    Req.Test.stub(HaToolStub, fn conn -> Req.Test.transport_error(conn, :timeout) end)
    assert {:ok, %{error: err}} = Tool.execute("home_state", %{}, @ctx)
    assert err =~ "home hub"
  end

  test "home_state caches for ~10s and normalizes the query cache key" do
    assert Tool.cache_ttl("home_state") == 10_000

    assert Tool.cache_key("home_state", %{"query" => "  Kitchen "}) ==
             Tool.cache_key("home_state", %{"query" => "kitchen"})

    assert Tool.cache_key("home_state", %{}) == Tool.cache_key("home_state", %{"query" => nil})
  end

  test "home_state has bridge phrases" do
    assert Tool.bridge("home_state") != []
  end

  # ---- home_control ----

  # Stub GET /api/states + POST service; sends {:service_called, path, body} to the test pid.
  defp stub_states_and_service(entities) do
    parent = self()

    Req.Test.stub(HaToolStub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/states"} ->
          Req.Test.json(conn, entities)

        {"POST", "/api/services/" <> _ = path} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(parent, {:service_called, path, Jason.decode!(body)})
          Req.Test.json(conn, [])
      end
    end)
  end

  @home [
    %{
      "entity_id" => "light.kitchen",
      "state" => "on",
      "attributes" => %{"friendly_name" => "Kitchen Light"}
    },
    %{
      "entity_id" => "lock.front_door",
      "state" => "locked",
      "attributes" => %{"friendly_name" => "Front Door"}
    },
    %{
      "entity_id" => "cover.garage_door",
      "state" => "closed",
      "attributes" => %{"friendly_name" => "Garage Door", "device_class" => "garage"}
    },
    %{
      "entity_id" => "cover.blinds",
      "state" => "open",
      "attributes" => %{"friendly_name" => "Living Room Blinds"}
    },
    %{
      "entity_id" => "climate.hall",
      "state" => "cool",
      "attributes" => %{"friendly_name" => "Hall Thermostat"}
    }
  ]

  test "declarations include home_control (entity_id + action required)" do
    hc = Enum.find(Tool.declarations(), &(&1.name == "home_control"))
    assert hc
    assert Enum.sort(hc.parameters.required) == ["action", "entity_id"]
  end

  test "home_control maps a semantic action to the HA service call" do
    stub_states_and_service(@home)

    assert {:ok, %{done: "off", entity: "Kitchen Light", entity_id: "light.kitchen"}} =
             Tool.execute(
               "home_control",
               %{"entity_id" => "light.kitchen", "action" => "off"},
               @ctx
             )

    assert_received {:service_called, "/api/services/light/turn_off",
                     %{"entity_id" => "light.kitchen"}}
  end

  test "home_control passes a numeric value through the mapping (brightness), coercing strings" do
    stub_states_and_service(@home)

    assert {:ok, %{done: "set_brightness"}} =
             Tool.execute(
               "home_control",
               %{"entity_id" => "light.kitchen", "action" => "set_brightness", "value" => "40"},
               @ctx
             )

    assert_received {:service_called, "/api/services/light/turn_on",
                     %{"entity_id" => "light.kitchen", "brightness_pct" => 40}}
  end

  test "SAFETY: a lock can never be operated — benign note, NO service call" do
    stub_states_and_service(@home)

    assert {:ok, %{note: note}} =
             Tool.execute(
               "home_control",
               %{"entity_id" => "lock.front_door", "action" => "on"},
               @ctx
             )

    assert note =~ "view-only"
    refute_received {:service_called, _, _}
  end

  test "SAFETY: the garage-class cover is blocked, while plain blinds work" do
    stub_states_and_service(@home)

    assert {:ok, %{note: note}} =
             Tool.execute(
               "home_control",
               %{"entity_id" => "cover.garage_door", "action" => "on"},
               @ctx
             )

    assert note =~ "view-only"
    refute_received {:service_called, _, _}

    assert {:ok, %{done: "on"}} =
             Tool.execute(
               "home_control",
               %{"entity_id" => "cover.blinds", "action" => "on"},
               @ctx
             )

    assert_received {:service_called, "/api/services/cover/open_cover",
                     %{"entity_id" => "cover.blinds"}}
  end

  test "unknown entity_id → a 'no device' note (and no service call)" do
    stub_states_and_service(@home)

    assert {:ok, %{note: note}} =
             Tool.execute("home_control", %{"entity_id" => "light.attic", "action" => "on"}, @ctx)

    assert note =~ "no device"
    refute_received {:service_called, _, _}
  end

  test "unknown action and missing value → guidance notes" do
    stub_states_and_service(@home)

    assert {:ok, %{note: unknown}} =
             Tool.execute(
               "home_control",
               %{"entity_id" => "light.kitchen", "action" => "defenestrate"},
               @ctx
             )

    assert unknown =~ "actions:"

    assert {:ok, %{note: needs}} =
             Tool.execute(
               "home_control",
               %{"entity_id" => "climate.hall", "action" => "set_temperature"},
               @ctx
             )

    assert needs =~ "value"
    refute_received {:service_called, _, _}
  end

  test "malformed args are nil-safe (no crash, a guidance note)" do
    assert {:ok, %{note: _}} = Tool.execute("home_control", %{}, @ctx)
    assert {:ok, %{note: _}} = Tool.execute("home_control", %{"action" => "on"}, @ctx)
  end

  test "a failed service call flattens to an error note" do
    Req.Test.stub(HaToolStub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/states"} -> Req.Test.json(conn, @home)
        {"POST", _} -> Plug.Conn.send_resp(conn, 500, "boom")
      end
    end)

    assert {:ok, %{error: _}} =
             Tool.execute(
               "home_control",
               %{"entity_id" => "light.kitchen", "action" => "on"},
               @ctx
             )
  end

  test "home_control invalidates the home_state cache; has bridges; no TTL" do
    assert Tool.cache_invalidates("home_control") == ["home_state"]
    assert Tool.cache_invalidates("home_state") == []
    assert Tool.cache_ttl("home_control") == nil
    assert Tool.bridge("home_control") != []
  end

  # ---- home_index (v1.1) ----

  # GET /api/states → entities; POST /api/template → the areas JSON string (text body).
  defp stub_states_and_areas(entities, areas_json) do
    Req.Test.stub(HaToolStub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/states"} -> Req.Test.json(conn, entities)
        {"POST", "/api/template"} -> Plug.Conn.send_resp(conn, 200, areas_json)
      end
    end)
  end

  test "declarations include home_index (no required args)" do
    idx = Enum.find(Tool.declarations(), &(&1.name == "home_index"))
    assert idx
    assert idx.parameters.required == []
  end

  test "home_index returns area + domain counts, total, and no_area" do
    entities = [
      %{
        "entity_id" => "light.kitchen",
        "state" => "on",
        "attributes" => %{"friendly_name" => "Kitchen Light"}
      },
      %{
        "entity_id" => "switch.kfan",
        "state" => "off",
        "attributes" => %{"friendly_name" => "Kitchen Fan"}
      },
      %{
        "entity_id" => "climate.hall",
        "state" => "heat",
        "attributes" => %{"friendly_name" => "Hall"}
      },
      %{"entity_id" => "sun.sun", "state" => "above_horizon", "attributes" => %{}}
    ]

    stub_states_and_areas(entities, ~s([["light.kitchen","Kitchen"],["switch.kfan","Kitchen"]]))

    assert {:ok, idx} = Tool.execute("home_index", %{}, @ctx)
    assert idx.total == 3
    assert idx.no_area == 1
    assert %{name: "Kitchen", count: 2} in idx.areas
    assert %{name: "light", count: 1} in idx.domains
  end

  test "home_index degrades to empty areas when the template call fails (no area requested)" do
    Req.Test.stub(HaToolStub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/states"} ->
          Req.Test.json(conn, [%{"entity_id" => "light.a", "state" => "on", "attributes" => %{}}])

        {"POST", "/api/template"} ->
          Plug.Conn.send_resp(conn, 500, "boom")
      end
    end)

    assert {:ok, %{areas: [], no_area: 1, total: 1}} = Tool.execute("home_index", %{}, @ctx)
  end

  test "home_index flattens an unreachable hub to an error note" do
    Req.Test.stub(HaToolStub, fn conn -> Req.Test.transport_error(conn, :timeout) end)
    assert {:ok, %{error: err}} = Tool.execute("home_index", %{}, @ctx)
    assert err =~ "home hub"
  end

  test "home_index caches ~60s and has a bridge" do
    assert Tool.cache_ttl("home_index") == 60_000
    assert Tool.bridge("home_index") != []
  end
end
