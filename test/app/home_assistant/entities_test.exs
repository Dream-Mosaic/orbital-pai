defmodule App.HomeAssistant.EntitiesTest do
  use ExUnit.Case, async: true

  alias App.HomeAssistant.Entities

  defp entity(id, attrs \\ %{}, state \\ "on"),
    do: %{"entity_id" => id, "state" => state, "attributes" => attrs}

  describe "classify/1" do
    test "v1 controllable domains" do
      for id <-
            ~w(light.kitchen switch.fan scene.movie script.bedtime media_player.tv climate.hall) do
        assert Entities.classify(entity(id)) == :controllable, "expected #{id} controllable"
      end
    end

    test "a plain cover (blinds) is controllable" do
      assert Entities.classify(entity("cover.blinds", %{"device_class" => "shade"})) ==
               :controllable

      assert Entities.classify(entity("cover.curtain")) == :controllable
    end

    test "lock and alarm_control_panel are sensitive read-only" do
      assert Entities.classify(entity("lock.front_door")) == :sensitive_read_only
      assert Entities.classify(entity("alarm_control_panel.home")) == :sensitive_read_only
    end

    test "a garage-class cover is sensitive read-only (the misheard-unlock case)" do
      assert Entities.classify(entity("cover.garage_door", %{"device_class" => "garage"})) ==
               :sensitive_read_only
    end

    test "sensors are read-only (reportable, not controllable)" do
      assert Entities.classify(entity("sensor.hall_temp", %{"unit_of_measurement" => "°F"}, "72")) ==
               :read_only

      assert Entities.classify(
               entity("binary_sensor.back_door", %{"device_class" => "door"}, "off")
             ) == :read_only
    end

    test "noise domains and anything unrecognized are ignored" do
      for id <-
            ~w(sun.sun update.core person.david zone.home device_tracker.phone automation.x weather.home unknown_domain.thing) do
        assert Entities.classify(entity(id)) == :ignore, "expected #{id} ignored"
      end
    end
  end

  describe "service_for/3 — the action→service map (safety lives here)" do
    test "light: on/off/toggle/set_brightness" do
      l = entity("light.kitchen")
      assert Entities.service_for(l, "on", nil) == {:ok, {"light", "turn_on", %{}}}
      assert Entities.service_for(l, "off", nil) == {:ok, {"light", "turn_off", %{}}}
      assert Entities.service_for(l, "toggle", nil) == {:ok, {"light", "toggle", %{}}}

      assert Entities.service_for(l, "set_brightness", 50) ==
               {:ok, {"light", "turn_on", %{brightness_pct: 50}}}

      # clamped
      assert Entities.service_for(l, "set_brightness", 250) ==
               {:ok, {"light", "turn_on", %{brightness_pct: 100}}}

      assert Entities.service_for(l, "set_brightness", nil) == {:error, :needs_value}
    end

    test "switch: on/off/toggle" do
      s = entity("switch.fan")
      assert Entities.service_for(s, "on", nil) == {:ok, {"switch", "turn_on", %{}}}
      assert Entities.service_for(s, "off", nil) == {:ok, {"switch", "turn_off", %{}}}
      assert Entities.service_for(s, "toggle", nil) == {:ok, {"switch", "toggle", %{}}}
    end

    test "scene + script: activate (and on) → turn_on" do
      assert Entities.service_for(entity("scene.movie"), "activate", nil) ==
               {:ok, {"scene", "turn_on", %{}}}

      assert Entities.service_for(entity("scene.movie"), "on", nil) ==
               {:ok, {"scene", "turn_on", %{}}}

      assert Entities.service_for(entity("script.bedtime"), "activate", nil) ==
               {:ok, {"script", "turn_on", %{}}}
    end

    test "media_player: play/pause/next/volume_set/on/off" do
      m = entity("media_player.tv")
      assert Entities.service_for(m, "play", nil) == {:ok, {"media_player", "media_play", %{}}}
      assert Entities.service_for(m, "pause", nil) == {:ok, {"media_player", "media_pause", %{}}}

      assert Entities.service_for(m, "next", nil) ==
               {:ok, {"media_player", "media_next_track", %{}}}

      assert Entities.service_for(m, "on", nil) == {:ok, {"media_player", "turn_on", %{}}}
      assert Entities.service_for(m, "off", nil) == {:ok, {"media_player", "turn_off", %{}}}
      # spoken percent normalizes to HA's 0.0–1.0
      assert Entities.service_for(m, "volume_set", 40) ==
               {:ok, {"media_player", "volume_set", %{volume_level: 0.4}}}

      assert Entities.service_for(m, "volume_set", 0.4) ==
               {:ok, {"media_player", "volume_set", %{volume_level: 0.4}}}

      assert Entities.service_for(m, "volume_set", nil) == {:error, :needs_value}
    end

    test "climate: set_temperature/on/off" do
      c = entity("climate.hall")

      assert Entities.service_for(c, "set_temperature", 72) ==
               {:ok, {"climate", "set_temperature", %{temperature: 72}}}

      assert Entities.service_for(c, "set_temperature", nil) == {:error, :needs_value}
      assert Entities.service_for(c, "on", nil) == {:ok, {"climate", "turn_on", %{}}}
      assert Entities.service_for(c, "off", nil) == {:ok, {"climate", "turn_off", %{}}}
    end

    test "plain cover: on=open, off=close, toggle" do
      b = entity("cover.blinds")
      assert Entities.service_for(b, "on", nil) == {:ok, {"cover", "open_cover", %{}}}
      assert Entities.service_for(b, "off", nil) == {:ok, {"cover", "close_cover", %{}}}
      assert Entities.service_for(b, "toggle", nil) == {:ok, {"cover", "toggle", %{}}}
    end

    test "STRUCTURAL SAFETY: lock, alarm, and garage cover have NO mapping for ANY action" do
      for e <- [
            entity("lock.front_door"),
            entity("alarm_control_panel.home"),
            entity("cover.garage_door", %{"device_class" => "garage"})
          ],
          action <-
            ~w(on off toggle activate set_brightness set_temperature play pause next volume_set unlock open) do
        assert Entities.service_for(e, action, 50) == {:error, :not_controllable},
               "#{e["entity_id"]} must be uncontrollable (action #{action})"
      end
    end

    test "sensors are not controllable; unknown actions are rejected" do
      assert Entities.service_for(entity("sensor.hall_temp"), "on", nil) ==
               {:error, :not_controllable}

      assert Entities.service_for(entity("light.kitchen"), "defenestrate", nil) ==
               {:error, :unknown_action}
    end
  end

  describe "compact/1 + compact_states/2" do
    test "keeps the brain-relevant core and drops nil fields" do
      c =
        Entities.compact(
          entity("light.kitchen", %{"friendly_name" => "Kitchen Light", "brightness" => 128})
        )

      assert c == %{
               entity_id: "light.kitchen",
               name: "Kitchen Light",
               domain: "light",
               state: "on",
               brightness_pct: 50
             }
    end

    test "falls back to entity_id when there's no friendly_name" do
      assert Entities.compact(entity("switch.fan")).name == "switch.fan"
    end

    test "keeps sensor unit, climate temps, media title/volume, cover position + device_class" do
      s = Entities.compact(entity("sensor.hall_temp", %{"unit_of_measurement" => "°F"}, "72"))
      assert s.unit == "°F" and s.state == "72"

      cl =
        Entities.compact(
          entity("climate.hall", %{"temperature" => 72, "current_temperature" => 74.5}, "cool")
        )

      assert cl.temperature == 72 and cl.current_temperature == 74.5

      m =
        Entities.compact(
          entity("media_player.tv", %{"media_title" => "Bluey", "volume_level" => 0.3}, "playing")
        )

      assert m.media_title == "Bluey" and m.volume_level == 0.3

      g =
        Entities.compact(
          entity(
            "cover.garage_door",
            %{"device_class" => "garage", "current_position" => 0},
            "closed"
          )
        )

      assert g.device_class == "garage" and g.position == 0
    end

    test "compact_states drops :ignore entities and applies the query filter (name/entity_id/domain, case-insensitive)" do
      raw = [
        entity("light.kitchen", %{"friendly_name" => "Kitchen Light"}),
        entity("light.bedroom", %{"friendly_name" => "Bedroom Lamp"}),
        entity("lock.front_door", %{"friendly_name" => "Front Door"}),
        entity("sun.sun")
      ]

      all = Entities.compact_states(raw, nil)

      assert Enum.map(all, & &1.entity_id) == [
               "light.kitchen",
               "light.bedroom",
               "lock.front_door"
             ]

      assert [%{entity_id: "light.kitchen"}] = Entities.compact_states(raw, "Kitchen")
      # domain query
      assert length(Entities.compact_states(raw, "light")) == 2
      # blank query = no filter
      assert length(Entities.compact_states(raw, "  ")) == 3
    end
  end
end
