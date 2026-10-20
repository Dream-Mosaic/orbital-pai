defmodule App.Tools.HomeAssistantTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias App.HomeAssistant.Actions
  alias App.HomeAssistant.Directory
  alias App.Test.HomeFixture
  alias App.Tools.HomeAssistant, as: Tool

  # async: false — mutates global app env (:home_assistant, req opts, the directory seam).

  @ctx %{session_id: "test", config: App.Config.default()}
  @unreachable "couldn't reach the home hub (the house connection isn't up yet)"

  setup do
    Application.put_env(:app, :home_assistant, %{
      url: "https://ha.example.test",
      token: "test-token"
    })

    Application.put_env(:app, :home_assistant_req_opts, plug: {Req.Test, HaToolStub})
    Application.put_env(:app, :home_assistant_directory, HomeFixture.directory())

    on_exit(fn ->
      Application.delete_env(:app, :home_assistant)
      Application.delete_env(:app, :home_assistant_req_opts)
      Application.delete_env(:app, :home_assistant_directory)
    end)

    stub(200)
    :ok
  end

  # Every request HA receives is recorded to the test process as {:ha, method, path, json_body}.
  defp stub(status) do
    test = self()

    Req.Test.stub(HaToolStub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      send(
        test,
        {:ha, conn.method, conn.request_path, if(raw == "", do: nil, else: Jason.decode!(raw))}
      )

      conn |> Plug.Conn.put_status(status) |> Req.Test.json([])
    end)
  end

  # Drain the recorded requests: [{method, path, body}], oldest first.
  defp requests do
    receive do
      {:ha, method, path, body} -> [{method, path, body} | requests()]
    after
      0 -> []
    end
  end

  defp posts, do: for({"POST", path, body} <- requests(), do: {path, body})

  defp control(targets, action, extra \\ %{}) do
    Tool.execute(
      "home_control",
      Map.merge(%{"targets" => targets, "action" => action}, extra),
      @ctx
    )
  end

  defp put_directory(fun), do: Application.put_env(:app, :home_assistant_directory, fun)

  defp decl(name), do: Enum.find(Tool.declarations(), &(&1.name == name))

  # ---- declarations / registry ----

  test "the declarations are exactly home_control, home_status and play_music" do
    assert Enum.map(Tool.declarations(), & &1.name) == [
             "home_control",
             "home_status",
             "play_music"
           ]
  end

  test "home_control takes the user's words as targets and an action from the closed vocabulary" do
    d = decl("home_control")
    assert d.parameters.required == ["targets", "action"]
    assert d.parameters.properties.targets.type == "array"
    assert d.parameters.properties.targets.items == %{type: "string"}
    assert d.parameters.properties.action.enum == Actions.actions()
    assert d.parameters.properties.value.type == "number"

    for k <- [:color, :effect], do: assert(d.parameters.properties[k].type == "string")
  end

  test "home_status: targets and state are both optional" do
    d = decl("home_status")
    assert d.parameters.required == []
    assert d.parameters.properties.targets.type == "array"
    assert d.parameters.properties.state.type == "string"
  end

  test "home_status is a read; home_control and play_music are writes" do
    assert App.Tools.read_only?("home_status")
    refute App.Tools.read_only?("home_control")
    refute App.Tools.read_only?("play_music")
  end

  test "bridges, and no tool cache (the directory is live)" do
    assert Tool.bridge("home_control") == ["On it.", "Sure — one sec.", "Doing that now."]
    assert Tool.bridge("home_status") == ["Checking the house.", "One sec — looking."]
    assert Tool.bridge("play_music") != []

    Code.ensure_loaded!(Tool)
    refute function_exported?(Tool, :cache_ttl, 1)
    refute function_exported?(Tool, :cache_key, 2)
    refute function_exported?(Tool, :cache_invalidates, 1)
  end

  # ---- home_control: one call ----

  test "\"gaming lights\" on → exactly one turn_on for the group" do
    assert {:ok, r} = control(["gaming lights"], "on")

    assert [{"/api/services/light/turn_on", %{"entity_id" => ["light.gaming_room_lights"]}}] =
             posts()

    assert [%{name: "Gaming lights", entity_id: "light.gaming_room_lights", set: "on"}] = r.done
    refute Map.has_key?(r, :note)
    refute Map.has_key?(r, :as_of)
  end

  test "set_color blue → rgb_color [0, 0, 255], and the result says what was set" do
    assert {:ok, r} = control(["gaming lights"], "set_color", %{"color" => "blue"})

    assert [
             {"/api/services/light/turn_on",
              %{"entity_id" => ["light.gaming_room_lights"], "rgb_color" => [0, 0, 255]}}
           ] = posts()

    assert [%{set: %{rgb_color: [0, 0, 255]}}] = r.done
  end

  test "two targets in different domains → one call per domain" do
    assert {:ok, r} = control(["gaming lights", "the fireplace"], "off")

    assert posts() |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
             ["/api/services/light/turn_off", "/api/services/switch/turn_off"]

    assert r.done |> Enum.map(& &1.entity_id) |> Enum.sort() ==
             ["light.gaming_room_lights", "switch.fireplace_switch"]
  end

  test "the same kind of action on several targets shares ONE call" do
    assert {:ok, r} = control(["gaming lights", "hall nightlight"], "on")

    assert [{"/api/services/light/turn_on", %{"entity_id" => ids}}] = posts()
    assert Enum.sort(ids) == ["light.gaming_room_lights", "light.hall_nightlight"]
    assert length(r.done) == 2
  end

  test "\"night lights\" off → input_boolean.turn_off" do
    assert {:ok, %{done: [_]}} = control(["night lights"], "off")

    assert [
             {"/api/services/input_boolean/turn_off",
              %{"entity_id" => ["input_boolean.night_lights"]}}
           ] =
             posts()
  end

  test "an exact entity_id in state `unknown` is NOT offline: the call goes out" do
    assert {:ok, %{done: [_]}} = control(["switch.govee_music_sync_box_power_switch"], "on")

    assert [
             {"/api/services/switch/turn_on",
              %{"entity_id" => ["switch.govee_music_sync_box_power_switch"]}}
           ] = posts()
  end

  test "dispatched through the registry (its own task), the calls still go out" do
    ctx = %{session_id: "test", config: %App.Config{tools: [Tool]}}

    assert {:ok, %{done: [_, _]}} =
             App.Tools.execute(
               "home_control",
               %{"targets" => ["gaming lights", "fireplace"], "action" => "on"},
               ctx
             )

    assert length(posts()) == 2
  end

  test "a bare `target` string is accepted" do
    assert {:ok, %{done: [%{entity_id: "switch.fireplace_switch"}]}} =
             Tool.execute("home_control", %{"target" => "fireplace", "action" => "on"}, @ctx)

    assert [{"/api/services/switch/turn_on", _}] = posts()
  end

  test "a number sent as a string still sets the value" do
    assert {:ok, _} = control(["gaming lights"], "set_brightness", %{"value" => "50"})

    assert [{"/api/services/light/turn_on", %{"brightness_pct" => 50}}] = posts()
  end

  # ---- home_control: honest outcomes ----

  test "an offline (unavailable) target is never called and is named as offline" do
    assert {:ok, r} = control(["pantry light"], "on")
    assert posts() == []
    assert r.offline == ["Pantry Lighy"]
    refute Map.has_key?(r, :done)
    assert r.note =~ "offline"
  end

  test "with several targets the reachable ones act and the offline ones are named" do
    assert {:ok, r} = control(["pantry light", "fireplace"], "on")

    assert [{"/api/services/switch/turn_on", %{"entity_id" => ["switch.fireplace_switch"]}}] =
             posts()

    assert [%{entity_id: "switch.fireplace_switch"}] = r.done
    assert r.offline == ["Pantry Lighy"]
  end

  test "a room fans out to LIGHTS only — never the homelab outlets" do
    assert {:ok, r} = control(["basement"], "off")
    calls = posts()

    assert calls != []
    assert Enum.all?(calls, fn {path, _} -> path == "/api/services/light/turn_off" end)
    ids = Enum.flat_map(calls, fn {_, body} -> body["entity_id"] end)
    refute Enum.any?(ids, &String.starts_with?(&1, "switch."))
    assert length(r.done) == 7
    # the 3D printer's chamber light is the Basement's one offline light
    assert r.offline == ["X1C_00M00A321800152 Chamber light"]
    assert r.note =~ "only its lights, never plugs or switches"
    assert r.note =~ "offline"
  end

  test "the whole house: one call for every reachable light, the offline ones named" do
    assert {:ok, r} = control(["all the lights"], "off")

    assert [{"/api/services/light/turn_off", %{"entity_id" => ids}}] = posts()
    assert "light.gaming_room_lights" in ids
    refute "light.pantry_lighy" in ids
    assert "Pantry Lighy" in r.offline
    # "all the lights" said lights itself: no plugs-and-switches disclaimer
    refute r.note =~ "never plugs"
  end

  test "a room named on its own gets the lights-only policy; \"<room> lights\" doesn't" do
    assert {:ok, r} = control(["living room"], "off")
    assert length(r.done) == 3

    assert r.note ==
             "A room or the whole house switches only its lights, never plugs or switches; " <>
               "anything named on its own was handled separately."

    assert {:ok, r} = control(["living room lights"], "off")
    assert length(r.done) == 3
    refute Map.has_key?(r, :note)
  end

  test "a room plus a named switch: the note never contradicts what was done" do
    assert {:ok, r} = control(["basement", "the fireplace"], "off")

    assert "switch.fireplace_switch" in Enum.map(r.done, & &1.entity_id)
    assert r.note =~ "only its lights, never plugs or switches"
    refute r.note =~ "fireplace"
    refute r.note =~ "left alone"
  end

  test "while the house connection is down, offline is last-known and the result says so" do
    put_directory(Directory.set_connected(HomeFixture.directory(), false))

    assert {:ok, r} = control(["pantry light"], "on")
    assert posts() == []
    assert r.offline == ["Pantry Lighy"]
    assert r.as_of =~ "ago — the house connection is down"
    assert r.note =~ "last seen offline"

    assert {:ok, %{done: [_], as_of: _}} = control(["fireplace"], "on")
  end

  test "a lock is view-only: no call, view_only says so" do
    assert {:ok, r} = control(["the front door lock"], "toggle")
    assert posts() == []
    assert r.view_only == ["U-Bolt Pro Z-Wave Smart Lock"]
    refute Map.has_key?(r, :done)
  end

  test "a name that matches nothing → not_found, no call" do
    assert {:ok, r} = control(["zorblax"], "on")
    assert posts() == []
    assert [%{target: "zorblax", close: []}] = r.not_found
  end

  test "an unsure match → ask with candidates, no call" do
    assert {:ok, r} = control(["the bedroom thermostat"], "set_temperature", %{"value" => 68})
    assert posts() == []

    assert [%{target: "the bedroom thermostat", candidates: [c | _]}] = r.ask

    assert %{name: "Living Room Thermostat", entity_id: "climate.living_room_thermostat"} = c
    assert c.state == "heat_cool"

    assert r.note ==
             "Ask which one — name the top two or three, then call again with the exact entity_id."
  end

  test "a bare \"the lights\" → which_room, no call" do
    assert {:ok, r} = control(["the lights"], "off")
    assert posts() == []
    assert "Basement" in r.which_room
  end

  test "an action the device can't do → cant with a plain-English why" do
    on_line = fn dir ->
      raw = Directory.state(dir, "light.pantry_lighy")
      Directory.put_state(dir, "light.pantry_lighy", %{raw | "state" => "off"})
    end

    put_directory(on_line.(HomeFixture.directory()))

    assert {:ok, r} = control(["pantry light"], "set_color", %{"color" => "blue"})
    assert posts() == []
    assert [%{name: "Pantry Lighy", why: why}] = r.cant
    assert why =~ "only does brightness"

    assert {:ok, r} = control(["fireplace"], "set_brightness", %{"value" => 40})
    assert [%{name: "Fireplace Switch", why: why}] = r.cant
    assert why =~ "switch"

    assert {:ok, r} = control(["gaming lights"], "set_color", %{"color" => "blurple"})
    assert [%{why: why}] = r.cant
    assert why =~ "blurple"

    assert {:ok, r} = control(["gaming lights"], "set_brightness")
    assert [%{why: why}] = r.cant
    assert why =~ "needs"
    assert posts() == []
  end

  test "a failed service call → cant (the home hub had trouble), never a crash" do
    stub(500)

    assert {:ok, r} = control(["fireplace"], "on")
    assert r.cant == [%{name: "Fireplace Switch", why: "the home hub had trouble"}]
    refute Map.has_key?(r, :done)
  end

  @in_time "the home hub didn't answer in time — it may still happen"

  test "a call that runs past its budget → it may still happen, never \"trouble\"" do
    Application.put_env(:app, :home_assistant_call_timeout_ms, 50)
    on_exit(fn -> Application.delete_env(:app, :home_assistant_call_timeout_ms) end)

    Req.Test.stub(HaToolStub, fn conn ->
      Process.sleep(500)
      Req.Test.json(conn, [])
    end)

    log =
      capture_log(fn ->
        assert {:ok, r} = control(["fireplace"], "on")
        assert r.cant == [%{name: "Fireplace Switch", why: @in_time}]
        refute Map.has_key?(r, :done)
      end)

    assert log =~ "[home] control switch.fireplace_switch switch.turn_on error (:timeout)"
  end

  test "an HTTP receive timeout is the same: HA may have acted" do
    Req.Test.stub(HaToolStub, &Req.Test.transport_error(&1, :timeout))

    assert {:ok, r} = control(["fireplace"], "on")
    assert r.cant == [%{name: "Fireplace Switch", why: @in_time}]
  end

  test "missing targets or an unknown action → a guidance note, no call" do
    assert {:ok, %{note: note}} = Tool.execute("home_control", %{"action" => "on"}, @ctx)
    assert note =~ "targets"

    assert {:ok, %{note: note}} = control(["fireplace"], "explode")
    assert note =~ "explode"

    assert {:ok, %{note: _}} = Tool.execute("home_control", %{"targets" => ["fireplace"]}, @ctx)

    assert {:ok, %{note: _}} =
             Tool.execute("home_control", %{"targets" => [42], "action" => "on"}, @ctx)

    assert posts() == []
  end

  # ---- the directory isn't there ----

  test "directory not loaded → every tool says it can't reach the hub, no HTTP call" do
    put_directory(fn -> {:error, :not_loaded} end)

    for {name, args} <- [
          {"home_control", %{"targets" => ["fireplace"], "action" => "on"}},
          {"home_status", %{"targets" => ["fireplace"]}},
          {"home_status", %{}},
          {"play_music", %{"query" => "jazz", "player" => "kitchen"}}
        ] do
      assert Tool.execute(name, args, @ctx) == {:ok, %{error: @unreachable}}, name
    end

    assert requests() == []
  end

  test "an unconfigured hub says so" do
    put_directory(fn -> {:error, :not_configured} end)

    assert {:ok, %{error: "the home hub isn't configured on this server"}} =
             control(["fireplace"], "on")
  end

  # ---- home_status ----

  test "home_status reads from the directory: a row per device, no HTTP" do
    assert {:ok, %{devices: [row]} = r} =
             Tool.execute("home_status", %{"targets" => ["fireplace"]}, @ctx)

    assert %{entity_id: "switch.fireplace_switch", name: "Fireplace Switch", state: "off"} = row
    assert row.area == "Living Room"
    refute Map.has_key?(row, :offline)
    refute Map.has_key?(r, :as_of)
    assert requests() == []
  end

  test "home_status flags an offline device" do
    assert {:ok, %{devices: [row]}} =
             Tool.execute("home_status", %{"targets" => ["pantry light"]}, @ctx)

    assert %{entity_id: "light.pantry_lighy", state: "unavailable", offline: true} = row
  end

  test "home_status filters by state" do
    assert {:ok, %{devices: rows}} =
             Tool.execute(
               "home_status",
               %{"targets" => ["all the lights"], "state" => "on"},
               @ctx
             )

    assert rows != []
    assert Enum.all?(rows, &(&1.state == "on"))
    assert "light.gaming_room_lights" in Enum.map(rows, & &1.entity_id)

    assert {:ok, %{devices: [], note: note}} =
             Tool.execute("home_status", %{"targets" => ["fireplace"], "state" => "on"}, @ctx)

    assert note =~ "on"
  end

  test "home_status with no targets → the overview: rooms, what's on, what's open" do
    assert {:ok, r} = Tool.execute("home_status", %{}, @ctx)
    assert "Basement" in r.rooms
    assert "Gaming lights" in r.on
    # a group that's on stands for its bulbs
    refute "Gaming room light 1" in r.on
    assert is_list(r.open)
    assert length(r.on) <= 25
    refute Map.has_key?(r, :as_of)
  end

  test "home_status says the state is last-known when the house connection is down" do
    put_directory(Directory.set_connected(HomeFixture.directory(), false))

    assert {:ok, %{as_of: as_of}} = Tool.execute("home_status", %{}, @ctx)
    assert as_of =~ "ago — the house connection is down"

    assert {:ok, %{devices: [_], as_of: _}} =
             Tool.execute("home_status", %{"targets" => ["fireplace"]}, @ctx)
  end

  test "home_status passes ask / not_found through like home_control" do
    assert {:ok, r} = Tool.execute("home_status", %{"targets" => ["zorblax"]}, @ctx)
    assert [%{target: "zorblax"}] = r.not_found
  end

  # ---- logging (spec §2.7) ----

  test "one resolve line per target and one control line per call" do
    prev = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: prev) end)

    log = capture_log(fn -> control(["gaming lights", "pantry light"], "on") end)

    assert log =~ ~s([home] resolve "gaming lights" → light.gaming_room_lights)
    assert log =~ ~s([home] resolve "pantry light" → light.pantry_lighy)
    assert log =~ "offline"
    assert log =~ ~r/\[home\] control light\.gaming_room_lights light\.turn_on %\{\} ok in \d+ms/
  end

  # ---- the silent no-op watch (spec §2.6) ----

  test "a device that never reports the new state is logged, without touching the answer" do
    Application.put_env(:app, :home_assistant_watch_ms, 40)
    on_exit(fn -> Application.put_env(:app, :home_assistant_watch_ms, 0) end)

    log =
      capture_log(fn ->
        # the fixture's fireplace stays "off" no matter what we ask
        assert {:ok, %{done: [_]}} = control(["fireplace"], "on")
        Process.sleep(250)
      end)

    assert log =~ ~s([home] switch.fireplace_switch did not report "on" within 40ms)
  end

  test "watch/3 returns quietly once the directory shows the state" do
    on = fn dir ->
      raw = Directory.state(dir, "switch.fireplace_switch")
      Directory.put_state(dir, "switch.fireplace_switch", %{raw | "state" => "on"})
    end

    put_directory(on.(HomeFixture.directory()))
    assert Tool.watch(["switch.fireplace_switch"], "on", 40) == :ok

    log =
      capture_log(fn ->
        assert {:missed, ["switch.fireplace_switch"]} =
                 Tool.watch(["switch.fireplace_switch"], "off", 40)
      end)

    assert log =~ ~s([home] switch.fireplace_switch did not report "off" within 40ms)
  end

  # ---- play_music (players come from the directory) ----

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

  defp with_states(states),
    do: put_directory(Directory.build(%{states: states}, ~U[2026-10-19 20:00:00Z]))

  test "declarations include play_music (query required; player/media_type/enqueue optional)" do
    pm = decl("play_music")
    assert pm.parameters.required == ["query"]

    for k <- [:query, :player, :media_type, :enqueue] do
      assert Map.has_key?(pm.parameters.properties, k), "play_music should accept #{k}"
    end

    assert "artist" in pm.parameters.properties.media_type.enum
    assert "replace" in pm.parameters.properties.enqueue.enum
  end

  test "play_music on the household fixture finds the kitchen's Music Assistant player" do
    assert {:ok, %{playing: "jazz", player: "Sonos (kitchen)"}} =
             Tool.execute("play_music", %{"query" => "jazz", "player" => "kitchen"}, @ctx)

    assert [
             {"/api/services/music_assistant/play_media",
              %{"entity_id" => "media_player.sonos_kitchen", "media_id" => "jazz"}}
           ] = posts()
  end

  test "play_music posts entity_id + media_id + media_type + enqueue" do
    with_states(@ma_players)

    assert {:ok, %{playing: "The Beatles", player: "Sonos Kitchen", enqueue: "replace"}} =
             Tool.execute(
               "play_music",
               %{"query" => "The Beatles", "player" => "kitchen", "media_type" => "artist"},
               @ctx
             )

    assert [
             {"/api/services/music_assistant/play_media",
              %{
                "entity_id" => "media_player.sonos_kitchen",
                "media_id" => "The Beatles",
                "media_type" => "artist",
                "enqueue" => "replace"
              }}
           ] = posts()
  end

  test "media_type omitted from the request body when not given; enqueue passed through" do
    with_states(@ma_players)

    assert {:ok, %{enqueue: "add"}} =
             Tool.execute(
               "play_music",
               %{"query" => "Discover Weekly", "player" => "basement", "enqueue" => "add"},
               @ctx
             )

    assert [{_, body}] = posts()
    refute Map.has_key?(body, "media_type")
    assert body["enqueue"] == "add"
  end

  test "no player name + a single MA player → plays there without asking" do
    with_states([hd(@ma_players)])

    assert {:ok, %{player: "Sonos Kitchen"}} =
             Tool.execute("play_music", %{"query" => "jazz"}, @ctx)

    assert [{_, %{"entity_id" => "media_player.sonos_kitchen"}}] = posts()
  end

  test "no player name + multiple MA players → asks which room, no service call" do
    with_states(@ma_players)

    assert {:ok, %{note: note}} = Tool.execute("play_music", %{"query" => "jazz"}, @ctx)
    assert note =~ "which room"
    assert posts() == []
  end

  test "player name with no match → a note listing the real players, no service call" do
    with_states(@ma_players)

    assert {:ok, %{note: note}} =
             Tool.execute("play_music", %{"query" => "jazz", "player" => "garage"}, @ctx)

    assert note =~ "garage"
    assert note =~ "Sonos Kitchen"
    assert posts() == []
  end

  test "no MA players → a graceful note, no service call" do
    with_states([List.last(@ma_players)])

    assert {:ok, %{note: note}} = Tool.execute("play_music", %{"query" => "jazz"}, @ctx)
    assert note =~ "music players"
    assert posts() == []
  end

  test "an offline player is never called" do
    [kitchen | _] = @ma_players
    with_states([%{kitchen | "state" => "unavailable"}])

    assert {:ok, %{offline: ["Sonos Kitchen"]} = r} =
             Tool.execute("play_music", %{"query" => "jazz"}, @ctx)

    refute Map.has_key?(r, :as_of)
    assert posts() == []

    # house connection down: the same refusal, worded as last-known
    put_directory(
      Directory.set_connected(
        Directory.build(
          %{states: [%{kitchen | "state" => "unavailable"}]},
          ~U[2026-10-19 20:00:00Z]
        ),
        false
      )
    )

    assert {:ok, %{offline: ["Sonos Kitchen"], as_of: _, note: note}} =
             Tool.execute("play_music", %{"query" => "jazz"}, @ctx)

    assert note =~ "last seen offline"
  end

  test "a play_media failure flattens to an error note" do
    with_states(@ma_players)
    stub(500)

    assert {:ok, %{error: err}} =
             Tool.execute("play_music", %{"query" => "jazz", "player" => "kitchen"}, @ctx)

    assert err =~ "music service"
  end

  test "malformed args (no query) → a guidance note, no HTTP call" do
    assert {:ok, %{note: note}} = Tool.execute("play_music", %{}, @ctx)
    assert note =~ "query"

    assert {:ok, %{note: _}} = Tool.execute("play_music", %{"query" => ""}, @ctx)
    assert {:ok, %{note: _}} = Tool.execute("play_music", %{"query" => 42}, @ctx)
    assert requests() == []
  end
end
