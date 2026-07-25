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

  # GET /api/states → entities; POST /api/template → the areas JSON string (text body).
  defp stub_states_and_areas(entities, areas_json) do
    Req.Test.stub(HaToolStub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/states"} -> Req.Test.json(conn, entities)
        {"POST", "/api/template"} -> Plug.Conn.send_resp(conn, 200, areas_json)
      end
    end)
  end

  # ---- home_index ----

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

  # ---- home_find ----

  @find_home [
    %{
      "entity_id" => "light.kitchen_main",
      "state" => "on",
      "attributes" => %{"friendly_name" => "Kitchen Main Light", "brightness" => 255}
    },
    %{
      "entity_id" => "light.kitchen_under",
      "state" => "off",
      "attributes" => %{"friendly_name" => "Under Cabinet Light"}
    },
    %{
      "entity_id" => "climate.living",
      "state" => "heat_cool",
      "attributes" => %{
        "friendly_name" => "Living Room Thermostat",
        "target_temp_high" => 74,
        "target_temp_low" => 70,
        "current_temperature" => 72
      }
    },
    %{
      "entity_id" => "cover.garage_door",
      "state" => "closed",
      "attributes" => %{"friendly_name" => "Garage Door", "device_class" => "garage"}
    },
    %{"entity_id" => "sun.sun", "state" => "above_horizon", "attributes" => %{}}
  ]

  @find_areas ~s([["light.kitchen_main","Kitchen"],["light.kitchen_under","Kitchen"],["climate.living","Living Room"],["cover.garage_door","Garage"]])

  test "declarations include home_find (all optional args)" do
    f = Enum.find(Tool.declarations(), &(&1.name == "home_find"))
    assert f
    assert f.parameters.required == []

    for k <- [:name, :area, :domain, :state] do
      assert Map.has_key?(f.parameters.properties, k), "home_find should accept #{k}"
    end
  end

  test "home_find (≤20) returns rank-ordered lean rows with area enrichment" do
    stub_states_and_areas(@find_home, @find_areas)

    assert {:ok, %{entities: rows, count: 2}} =
             Tool.execute("home_find", %{"area" => "Kitchen", "domain" => "light"}, @ctx)

    assert Enum.sort(Enum.map(rows, & &1.entity_id)) == [
             "light.kitchen_main",
             "light.kitchen_under"
           ]

    assert Enum.all?(rows, &(&1.area == "Kitchen"))
  end

  test "a single match carries the extended attribute set (M5)" do
    stub_states_and_areas(@find_home, @find_areas)

    assert {:ok, %{entities: [row], count: 1}} =
             Tool.execute("home_find", %{"name" => "living room thermostat"}, @ctx)

    assert row.entity_id == "climate.living"
    assert row.target_temp_high == 74 and row.target_temp_low == 70
    assert row.current_temperature == 72
  end

  test "C1: area given but the rooms template failed → error, ZERO rows (never the unfiltered set)" do
    Req.Test.stub(HaToolStub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/states"} -> Req.Test.json(conn, @find_home)
        {"POST", "/api/template"} -> Plug.Conn.send_resp(conn, 500, "boom")
      end
    end)

    assert {:ok, result} = Tool.execute("home_find", %{"area" => "Kitchen"}, @ctx)
    assert Map.has_key?(result, :error)
    refute Map.has_key?(result, :entities)
  end

  test "empty result returns close_matches + an ask-the-user note (C3)" do
    stub_states_and_areas(@find_home, @find_areas)

    assert {:ok, %{entities: [], close_matches: close, note: note}} =
             Tool.execute("home_find", %{"name" => "kitchen lamp"}, @ctx)

    assert is_list(close) and close != []
    assert note =~ "ASK"
  end

  test "over cap WITH a name → top 20 by rank + a narrow note" do
    many =
      for i <- 1..30 do
        %{
          "entity_id" => "light.l#{i}",
          "state" => "on",
          "attributes" => %{"friendly_name" => "Ceiling Light #{i}"}
        }
      end

    stub_states_and_areas(many, ~s([]))

    assert {:ok, %{entities: rows, count: 30, note: note}} =
             Tool.execute("home_find", %{"name" => "light"}, @ctx)

    assert length(rows) == 20
    assert note =~ "closest"
  end

  test "over cap with NO name → area×count breakdown, NOT rows" do
    many =
      for i <- 1..30 do
        %{
          "entity_id" => "light.l#{i}",
          "state" => "on",
          "attributes" => %{"friendly_name" => "Light #{i}"}
        }
      end

    pairs =
      for i <- 1..30, do: ["light.l#{i}", if(rem(i, 2) == 0, do: "Kitchen", else: "Bedroom")]

    stub_states_and_areas(many, Jason.encode!(pairs))

    assert {:ok, result} = Tool.execute("home_find", %{"domain" => "light"}, @ctx)
    assert result.count == 30
    assert result.by_area["Kitchen"] == 15
    assert result.by_area["Bedroom"] == 15
    assert result.note =~ "too many"
    refute Map.has_key?(result, :entities)
  end

  test "home_find caches ~10s keyed on the normalized arg set" do
    assert Tool.cache_ttl("home_find") == 10_000

    assert Tool.cache_key("home_find", %{"name" => " Kitchen "}) ==
             Tool.cache_key("home_find", %{"name" => "kitchen"})
  end

  # ---- home_control (v1.1: single-entity state/1 + reports `set:`) ----

  # GET /api/states/<id> → the entity (404 if absent); POST service → notify the test pid.
  defp stub_entity_and_service(entities) do
    parent = self()
    by_id = Map.new(entities, &{&1["entity_id"], &1})

    Req.Test.stub(HaToolStub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/states/" <> id} ->
          case Map.get(by_id, id) do
            nil -> Plug.Conn.send_resp(conn, 404, "not found")
            e -> Req.Test.json(conn, e)
          end

        {"POST", "/api/services/" <> _ = path} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(parent, {:service_called, path, Jason.decode!(body)})
          Req.Test.json(conn, [])
      end
    end)
  end

  @control_home [
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
      "entity_id" => "climate.living",
      "state" => "heat_cool",
      "attributes" => %{
        "friendly_name" => "Living Room Thermostat",
        "target_temp_high" => 74,
        "target_temp_low" => 70
      }
    },
    %{
      "entity_id" => "fan.bedroom",
      "state" => "off",
      "attributes" => %{"friendly_name" => "Bedroom Fan"}
    }
  ]

  test "declarations: home_control requires entity_id + action and lists the new actions" do
    hc = Enum.find(Tool.declarations(), &(&1.name == "home_control"))
    assert Enum.sort(hc.parameters.required) == ["action", "entity_id"]
    assert "set_position" in hc.parameters.properties.action.enum
    assert "set_speed" in hc.parameters.properties.action.enum
  end

  test "control uses state/1 (single GET) and reports what it set" do
    stub_entity_and_service(@control_home)

    assert {:ok, %{done: "off", entity: "Kitchen Light", entity_id: "light.kitchen", set: %{}}} =
             Tool.execute(
               "home_control",
               %{"entity_id" => "light.kitchen", "action" => "off"},
               @ctx
             )

    assert_received {:service_called, "/api/services/light/turn_off",
                     %{"entity_id" => "light.kitchen"}}
  end

  test "heat_cool thermostat: sets the band and reports it (C2)" do
    stub_entity_and_service(@control_home)

    assert {:ok, %{done: "set_temperature", set: %{target_temp_low: 70, target_temp_high: 74}}} =
             Tool.execute(
               "home_control",
               %{"entity_id" => "climate.living", "action" => "set_temperature", "value" => 72},
               @ctx
             )

    assert_received {:service_called, "/api/services/climate/set_temperature", body}

    assert body == %{
             "entity_id" => "climate.living",
             "target_temp_low" => 70,
             "target_temp_high" => 74
           }
  end

  test "cover set_position + fan set_speed reach the new services and report `set:`" do
    stub_entity_and_service(@control_home)

    assert {:ok, %{done: "set_position", set: %{position: 60}}} =
             Tool.execute(
               "home_control",
               %{"entity_id" => "cover.blinds", "action" => "set_position", "value" => 60},
               @ctx
             )

    assert_received {:service_called, "/api/services/cover/set_cover_position",
                     %{"entity_id" => "cover.blinds", "position" => 60}}

    assert {:ok, %{done: "set_speed", set: %{percentage: 30}}} =
             Tool.execute(
               "home_control",
               %{"entity_id" => "fan.bedroom", "action" => "set_speed", "value" => 30},
               @ctx
             )

    assert_received {:service_called, "/api/services/fan/set_percentage",
                     %{"entity_id" => "fan.bedroom", "percentage" => 30}}
  end

  test "SAFETY: lock + garage cover blocked (benign note, NO service call); plain blinds still work" do
    stub_entity_and_service(@control_home)

    assert {:ok, %{note: n1}} =
             Tool.execute(
               "home_control",
               %{"entity_id" => "lock.front_door", "action" => "on"},
               @ctx
             )

    assert n1 =~ "view-only"

    assert {:ok, %{note: n2}} =
             Tool.execute(
               "home_control",
               %{"entity_id" => "cover.garage_door", "action" => "on"},
               @ctx
             )

    assert n2 =~ "view-only"
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

  test "unknown entity_id (404) → a no-device note, no service call" do
    stub_entity_and_service(@control_home)

    assert {:ok, %{note: note}} =
             Tool.execute("home_control", %{"entity_id" => "light.ghost", "action" => "on"}, @ctx)

    assert note =~ "no device"
    refute_received {:service_called, _, _}
  end

  test "unknown action + missing value → guidance notes" do
    stub_entity_and_service(@control_home)

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
               %{"entity_id" => "climate.living", "action" => "set_temperature"},
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
        {"GET", "/api/states/light.kitchen"} -> Req.Test.json(conn, hd(@control_home))
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

  test "home_control invalidates both read caches; no ttl; has a bridge" do
    assert Enum.sort(Tool.cache_invalidates("home_control")) == ["home_find", "home_index"]
    assert Tool.cache_invalidates("home_find") == []
    assert Tool.cache_ttl("home_control") == nil
    assert Tool.bridge("home_control") != []
  end

  # ---- play_music (v1.2) ----

  @ma_players [
    %{
      "entity_id" => "media_player.sonos_kitchen",
      "state" => "idle",
      "attributes" => %{"friendly_name" => "Sonos Kitchen", "active_queue" => "q1"}
    },
    %{
      "entity_id" => "media_player.sonos_basement",
      "state" => "idle",
      "attributes" => %{"friendly_name" => "Sonos Basement", "active_queue" => "q2"}
    },
    # native Sonos entity (no active_queue) — must never be targeted
    %{
      "entity_id" => "media_player.office",
      "state" => "idle",
      "attributes" => %{"friendly_name" => "Office"}
    }
  ]

  defp stub_states_and_service(entities) do
    parent = self()

    Req.Test.stub(HaToolStub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/states"} ->
          Req.Test.json(conn, entities)

        {"POST", "/api/services/music_assistant/play_media"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(parent, {:play_media_called, Jason.decode!(body)})
          Req.Test.json(conn, [])
      end
    end)
  end

  test "declarations include play_music (query required; player/media_type/enqueue optional)" do
    pm = Enum.find(Tool.declarations(), &(&1.name == "play_music"))
    assert pm
    assert pm.parameters.required == ["query"]

    for k <- [:query, :player, :media_type, :enqueue] do
      assert Map.has_key?(pm.parameters.properties, k), "play_music should accept #{k}"
    end

    assert "artist" in pm.parameters.properties.media_type.enum
    assert "replace" in pm.parameters.properties.enqueue.enum
  end

  test "play_music posts entity_id + media_id + media_type + enqueue to music_assistant/play_media" do
    stub_states_and_service(@ma_players)

    assert {:ok, %{playing: "The Beatles", player: "Sonos Kitchen", enqueue: "replace"}} =
             Tool.execute(
               "play_music",
               %{"query" => "The Beatles", "player" => "kitchen", "media_type" => "artist"},
               @ctx
             )

    assert_received {:play_media_called,
                     %{
                       "entity_id" => "media_player.sonos_kitchen",
                       "media_id" => "The Beatles",
                       "media_type" => "artist",
                       "enqueue" => "replace"
                     }}
  end

  test "media_type omitted from the request body when not given; enqueue passed through" do
    stub_states_and_service(@ma_players)

    assert {:ok, %{enqueue: "add"}} =
             Tool.execute(
               "play_music",
               %{"query" => "Discover Weekly", "player" => "basement", "enqueue" => "add"},
               @ctx
             )

    assert_received {:play_media_called, body}
    refute Map.has_key?(body, "media_type")
    assert body["enqueue"] == "add"
  end

  test "no player name + a single MA player → plays there without asking" do
    stub_states_and_service([hd(@ma_players)])

    assert {:ok, %{player: "Sonos Kitchen"}} =
             Tool.execute("play_music", %{"query" => "jazz"}, @ctx)

    assert_received {:play_media_called, %{"entity_id" => "media_player.sonos_kitchen"}}
  end

  test "no player name + multiple MA players → asks which room, no service call" do
    stub_states_and_service(@ma_players)

    assert {:ok, %{note: note}} = Tool.execute("play_music", %{"query" => "jazz"}, @ctx)
    assert note =~ "which room"
    refute_received {:play_media_called, _}
  end

  test "player name with no match → a note listing the real players, no service call" do
    stub_states_and_service(@ma_players)

    assert {:ok, %{note: note}} =
             Tool.execute(
               "play_music",
               %{"query" => "jazz", "player" => "garage"},
               @ctx
             )

    assert note =~ "garage"
    assert note =~ "Sonos Kitchen"
    refute_received {:play_media_called, _}
  end

  test "no MA players configured → a graceful note, no service call" do
    # a states list with zero active_queue entities (only the native, non-MA Sonos entity)
    Req.Test.stub(HaToolStub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/states"} ->
          Req.Test.json(conn, [
            %{
              "entity_id" => "media_player.office",
              "state" => "idle",
              "attributes" => %{"friendly_name" => "Office"}
            }
          ])

        {"POST", "/api/services/music_assistant/play_media"} ->
          flunk("should never call play_media with no MA players")
      end
    end)

    assert {:ok, %{note: note}} = Tool.execute("play_music", %{"query" => "jazz"}, @ctx)
    assert note =~ "music players"
  end

  test "a play_media failure flattens to an error note" do
    Req.Test.stub(HaToolStub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/states"} ->
          Req.Test.json(conn, @ma_players)

        {"POST", "/api/services/music_assistant/play_media"} ->
          Plug.Conn.send_resp(conn, 500, "boom")
      end
    end)

    assert {:ok, %{error: err}} =
             Tool.execute(
               "play_music",
               %{"query" => "jazz", "player" => "kitchen"},
               @ctx
             )

    assert err =~ "music service"
  end

  test "an unreachable hub flattens to an error note (no states fetched)" do
    Req.Test.stub(HaToolStub, fn conn -> Req.Test.transport_error(conn, :timeout) end)
    assert {:ok, %{error: err}} = Tool.execute("play_music", %{"query" => "jazz"}, @ctx)
    assert err =~ "home hub"
  end

  test "malformed args (no query) → a guidance note, no HTTP call" do
    Req.Test.stub(HaToolStub, fn _conn -> flunk("play_music must not call HA with no query") end)

    assert {:ok, %{note: note}} = Tool.execute("play_music", %{}, @ctx)
    assert note =~ "query"

    assert {:ok, %{note: _}} = Tool.execute("play_music", %{"query" => ""}, @ctx)
    assert {:ok, %{note: _}} = Tool.execute("play_music", %{"query" => 42}, @ctx)
  end

  test "play_music has a bridge and no cache" do
    assert Tool.bridge("play_music") != []
    assert Tool.cache_ttl("play_music") == nil
    assert Tool.cache_invalidates("play_music") == []
  end
end
