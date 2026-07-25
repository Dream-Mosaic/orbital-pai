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

  # Build a compacted + area-enriched entity, the shape match_name/filter operate on.
  defp enriched(id, area, attrs \\ %{}, state \\ "on") do
    entity(id, attrs, state) |> Entities.compact() |> Map.put(:area, area)
  end

  describe "compact/1 — temperature band (v1.1, C2)" do
    test "a heat_cool entity yields target_temp_high/low" do
      hc =
        Entities.compact(
          entity(
            "climate.living",
            %{
              "friendly_name" => "Living Room",
              "target_temp_high" => 75,
              "target_temp_low" => 70
            },
            "heat_cool"
          )
        )

      assert hc.target_temp_high == 75 and hc.target_temp_low == 70
    end

    test "a single-setpoint device has no band keys (nils dropped)" do
      sc = Entities.compact(entity("climate.hall", %{"temperature" => 72}, "heat"))
      refute Map.has_key?(sc, :target_temp_high)
      refute Map.has_key?(sc, :target_temp_low)
      assert sc.temperature == 72
    end
  end

  describe "match_name/2 — fuzzy, rank-ordered, plural-folded" do
    test "requires ALL tokens (order-independent) and folds plurals" do
      ents = [
        enriched("light.bedroom_night", nil, %{"friendly_name" => "Bedroom Night Light"}),
        enriched("light.kitchen", nil, %{"friendly_name" => "Kitchen Light"}),
        enriched("switch.porch", nil, %{"friendly_name" => "Porch Switch"})
      ]

      # "night lights" → tokens [night, light]; only Bedroom Night Light has both.
      assert Entities.match_name(ents, "night lights") |> Enum.map(& &1.entity_id) ==
               ["light.bedroom_night"]
    end

    test "plural fold: -es after ch/sh/x/s/z, single -s otherwise, never -ss" do
      switches = [
        enriched("switch.a", nil, %{"friendly_name" => "Hallway Switch"}),
        enriched("light.b", nil, %{"friendly_name" => "Hallway Light"})
      ]

      # "switches" → "switch"
      assert Entities.match_name(switches, "switches") |> Enum.map(& &1.entity_id) == ["switch.a"]

      glass = [
        enriched("sensor.g", nil, %{"friendly_name" => "Glass Break"}),
        enriched("sensor.h", nil, %{"friendly_name" => "Motion"})
      ]

      # "glass" must NOT fold to "glas" (never strip -ss) — it still matches "Glass Break".
      assert Entities.match_name(glass, "glass") |> Enum.map(& &1.entity_id) == ["sensor.g"]
    end

    test "ranks by Jaro descending (best first)" do
      ents = [
        enriched("light.kitchen_far", nil, %{"friendly_name" => "Kitchen Ceiling Fixture"}),
        enriched("light.kitchen", nil, %{"friendly_name" => "Kitchen Light"})
      ]

      # Both contain "kitchen"; "Kitchen Light" is the closer Jaro match to the query.
      assert Entities.match_name(ents, "kitchen light") |> hd() |> Map.get(:entity_id) ==
               "light.kitchen"
    end

    test "empty / blank name returns the input order unchanged" do
      ents = [enriched("light.a", nil), enriched("light.b", nil)]
      assert Entities.match_name(ents, "") == ents
    end
  end

  describe "close_matches/3 — word-anchored suggestions ignoring the ALL-tokens gate (C3)" do
    test "suggests names that share a query WORD, ranked by token overlap" do
      ents = [
        enriched("light.mbr", "Bedroom", %{"friendly_name" => "Master Bedroom Light"}),
        enriched("fan.mbr", "Bedroom", %{"friendly_name" => "Master Bedroom Fan"}),
        enriched("light.kit", "Kitchen", %{"friendly_name" => "Kitchen Light"}),
        enriched("light.gar", "Garage", %{"friendly_name" => "Garage Bulb"})
      ]

      # "lite" is no exact token of any name (match_name's gate misses it), but "master" +
      # "bedroom" anchor the two MBR entities (Kitchen/Garage share no word → excluded). Among
      # the survivors, "Light" outranks "Fan" on token overlap ("lite"≈"light"). Anchoring on a
      # shared word — not whole-string Jaro — is what makes noise return [] (next test).
      assert Entities.close_matches(ents, "master bedroom lite", 3) ==
               ["Master Bedroom Light", "Master Bedroom Fan"]
    end

    test "gibberish that shares no word returns [] — the brain asks instead of suggesting noise" do
      ents = [
        enriched("light.kit", "Kitchen", %{"friendly_name" => "Kitchen Light"}),
        enriched("sensor.ipad", "Office", %{"friendly_name" => "iPad Z Battery"})
      ]

      assert Entities.close_matches(ents, "zzznosuchthing", 3) == []
      assert Entities.close_matches(ents, "", 3) == []
    end
  end

  describe "enrich/2" do
    test "adds :area from the map, or leaves it off when absent" do
      c = Entities.compact(entity("light.kitchen", %{"friendly_name" => "Kitchen Light"}))
      assert Entities.enrich(c, %{"light.kitchen" => "Kitchen"}).area == "Kitchen"
      refute Map.has_key?(Entities.enrich(c, %{}), :area)
    end
  end

  describe "filter/2 — area (exact-or-unique-substring), domain, state, then name (M2)" do
    test "area: exact match, unique substring, ambiguous → none" do
      ents = [
        enriched("light.kitchen", "Kitchen"),
        enriched("light.family", "Family Room"),
        enriched("light.living", "Living Room")
      ]

      # exact (case-insensitive)
      assert Entities.filter(ents, %{area: "kitchen"}) |> Enum.map(& &1.entity_id) ==
               ["light.kitchen"]

      # unique substring
      assert Entities.filter(ents, %{area: "famil"}) |> Enum.map(& &1.entity_id) ==
               ["light.family"]

      # ambiguous substring ("room" ⊂ both Family Room and Living Room) → no match, no widening
      assert Entities.filter(ents, %{area: "room"}) == []
    end

    test "domain + state compose; nil dimensions are unfiltered" do
      ents = [
        enriched("light.a", "Kitchen", %{}, "on"),
        enriched("light.b", "Kitchen", %{}, "off"),
        enriched("switch.c", "Kitchen", %{}, "on")
      ]

      assert Entities.filter(ents, %{domain: "light"}) |> Enum.map(& &1.entity_id) ==
               ["light.a", "light.b"]

      assert Entities.filter(ents, %{domain: "light", state: "off"}) |> Enum.map(& &1.entity_id) ==
               ["light.b"]

      assert Entities.filter(ents, %{}) == ents
    end

    test "name filter runs last and sets the result order (rank)" do
      ents = [
        enriched("light.kitchen_main", "Kitchen", %{"friendly_name" => "Kitchen Main Light"}),
        enriched("light.kitchen_under", "Kitchen", %{"friendly_name" => "Under Cabinet Light"}),
        enriched("switch.kitchen_fan", "Kitchen", %{"friendly_name" => "Kitchen Fan"})
      ]

      assert Entities.filter(ents, %{area: "Kitchen", domain: "light", name: "main"})
             |> Enum.map(& &1.entity_id) == ["light.kitchen_main"]
    end
  end

  describe "index/2 — house map with no_area (M2)" do
    test "counts areas + domains, total, and no_area over the visible set (noise dropped)" do
      raw = [
        entity("light.kitchen"),
        entity("light.bedroom"),
        entity("switch.fan"),
        entity("climate.hall"),
        entity("sun.sun")
      ]

      area_map = %{
        "light.kitchen" => "Kitchen",
        "switch.fan" => "Kitchen",
        "light.bedroom" => "Bedroom"
      }

      idx = Entities.index(raw, area_map)

      assert idx.total == 4
      assert idx.no_area == 1
      assert %{name: "Kitchen", count: 2} in idx.areas
      assert %{name: "Bedroom", count: 1} in idx.areas

      assert Enum.sort_by(idx.domains, & &1.name) == [
               %{name: "climate", count: 1},
               %{name: "light", count: 2},
               %{name: "switch", count: 1}
             ]
    end
  end

  describe "service_for/3 — attribute-aware climate (the core fix, TABLE TESTS)" do
    test "state==heat_cool → RANGE even when `temperature` is also present (state discrimination, I2)" do
      e =
        entity(
          "climate.living",
          %{"temperature" => 72, "target_temp_high" => 74, "target_temp_low" => 70},
          "heat_cool"
        )

      assert Entities.service_for(e, "set_temperature", 72) ==
               {:ok, {"climate", "set_temperature", %{target_temp_low: 70, target_temp_high: 74}}}
    end

    test "band recenter preserves width, whole-degree default — 5° band, set 72 → 70/75 (69.5/74.5 rounded)" do
      e =
        entity(
          "climate.living",
          %{"target_temp_high" => 75, "target_temp_low" => 70},
          "heat_cool"
        )

      # recenter 72, width 5 → 69.5/74.5, then whole-degree default (no target_temp_step) → 70/75.
      assert Entities.service_for(e, "set_temperature", 72) ==
               {:ok, {"climate", "set_temperature", %{target_temp_low: 70, target_temp_high: 75}}}
    end

    test "deadband fallback of 4°F when the band is absent / zero-width" do
      e = entity("climate.living", %{}, "heat_cool")

      assert Entities.service_for(e, "set_temperature", 72) ==
               {:ok, {"climate", "set_temperature", %{target_temp_low: 70, target_temp_high: 74}}}
    end

    test "clamps the band into [min_temp, max_temp]" do
      e =
        entity(
          "climate.living",
          %{
            "target_temp_high" => 75,
            "target_temp_low" => 70,
            "min_temp" => 60,
            "max_temp" => 74
          },
          "heat_cool"
        )

      # width 5, recentre 76 → 73.5/78.5 → clamp into [60,74] → 73.5/74 → whole-degree → 74/74
      assert Entities.service_for(e, "set_temperature", 76) ==
               {:ok, {"climate", "set_temperature", %{target_temp_low: 74, target_temp_high: 74}}}
    end

    test "rounds to target_temp_step — step 1.0 kills the half degree" do
      e =
        entity(
          "climate.living",
          %{"target_temp_high" => 75, "target_temp_low" => 70, "target_temp_step" => 1.0},
          "heat_cool"
        )

      # width 5, recentre on 72 → 69.5 / 74.5 → step 1.0 → 70 / 75
      assert Entities.service_for(e, "set_temperature", 72) ==
               {:ok, {"climate", "set_temperature", %{target_temp_low: 70, target_temp_high: 75}}}
    end

    test "band present, non-heat_cool state, no `temperature` → STILL range" do
      e = entity("climate.eco", %{"target_temp_high" => 76, "target_temp_low" => 72}, "auto")

      assert Entities.service_for(e, "set_temperature", 72) ==
               {:ok, {"climate", "set_temperature", %{target_temp_low: 70, target_temp_high: 74}}}
    end

    test "single-setpoint (state heat, `temperature` present) → %{temperature: …}, clamped + stepped" do
      e =
        entity("climate.hall", %{"temperature" => 68, "min_temp" => 60, "max_temp" => 75}, "heat")

      assert Entities.service_for(e, "set_temperature", 90) ==
               {:ok, {"climate", "set_temperature", %{temperature: 75}}}

      assert Entities.service_for(e, "set_temperature", 71) ==
               {:ok, {"climate", "set_temperature", %{temperature: 71}}}
    end

    test "no state/temperature/band info → single-setpoint fallback (v1 behaviour preserved)" do
      e = entity("climate.plain", %{}, "on")

      assert Entities.service_for(e, "set_temperature", 72) ==
               {:ok, {"climate", "set_temperature", %{temperature: 72}}}

      assert Entities.service_for(e, "set_temperature", nil) == {:error, :needs_value}
    end
  end

  describe "service_for/3 — cover position + fan (v1.1 actions)" do
    test "cover set_position → set_cover_position, clamped 0–100" do
      c = entity("cover.blinds")

      assert Entities.service_for(c, "set_position", 50) ==
               {:ok, {"cover", "set_cover_position", %{position: 50}}}

      assert Entities.service_for(c, "set_position", 150) ==
               {:ok, {"cover", "set_cover_position", %{position: 100}}}

      assert Entities.service_for(c, "set_position", nil) == {:error, :needs_value}
    end

    test "fan is controllable and maps on/off/toggle + set_speed" do
      assert Entities.classify(entity("fan.bedroom")) == :controllable

      f = entity("fan.bedroom")
      assert Entities.service_for(f, "on", nil) == {:ok, {"fan", "turn_on", %{}}}
      assert Entities.service_for(f, "off", nil) == {:ok, {"fan", "turn_off", %{}}}
      assert Entities.service_for(f, "toggle", nil) == {:ok, {"fan", "toggle", %{}}}

      assert Entities.service_for(f, "set_speed", 40) ==
               {:ok, {"fan", "set_percentage", %{percentage: 40}}}

      assert Entities.service_for(f, "set_speed", 150) ==
               {:ok, {"fan", "set_percentage", %{percentage: 100}}}

      assert Entities.service_for(f, "set_speed", nil) == {:error, :needs_value}
    end

    test "STRUCTURAL SAFETY still holds for the new actions (lock / garage)" do
      for e <- [
            entity("lock.front_door"),
            entity("cover.garage_door", %{"device_class" => "garage"})
          ],
          action <- ~w(set_position set_speed) do
        assert Entities.service_for(e, action, 50) == {:error, :not_controllable},
               "#{e["entity_id"]} must stay uncontrollable (action #{action})"
      end
    end
  end
end
