defmodule App.HomeAssistant.ResolveTest do
  # Pure, but HA tests stay async: false (the house rule for this suite).
  use ExUnit.Case, async: false

  alias App.HomeAssistant.{Directory, Resolve}
  alias App.Test.HomeFixture

  setup_all do
    %{dir: HomeFixture.directory()}
  end

  defp ids(es), do: Enum.map(es, & &1.entity_id)

  # The household's own phrases against the real (sanitized) house. This table is the contract.
  for {phrase, mode, expect} <- [
        {"gaming lights", :control, {:ids, ["light.gaming_room_lights"]}},
        {"the gaming lights", :control, {:ids, ["light.gaming_room_lights"]}},
        {"Gaming Lights", :control, {:ids, ["light.gaming_room_lights"]}},
        {"the fireplace", :control, {:ids, ["switch.fireplace_switch"]}},
        {"fireplace", :status, {:ids, ["switch.fireplace_switch"]}},
        {"pantry light", :control, {:ids, ["light.pantry_lighy"]}},
        {"pantry lights", :control, {:ids, ["light.pantry_lighy"]}},
        {"night lights", :control, {:ids, ["input_boolean.night_lights"]}},
        {"the night light", :control, {:ids, ["input_boolean.night_lights"]}},
        {"hall nightlight", :control, {:ids, ["light.hall_nightlight"]}},
        {"kitchen lights", :control, {:ids, ["light.all_kitchen_lights"]}},
        {"bathroom lights", :control, {:ids, ["light.bathroom_lights"]}},
        {"basement", :control, :basement_lights},
        # The four dining room bulbs are hidden in HA (members of the group), so the group it is.
        {"dining room lights", :control, {:ids, ["light.dining_table_lights"]}},
        {"all the lights", :control, :house_lights},
        {"everything", :control, :house_lights},
        {"the lights", :control,
         {:which_room, ["Basement", "Game Room", "Garage", "Kitchen", "Living Room"]}},
        # "garage" next to a light noun is the room, not the door.
        {"lights in the garage", :control, {:ids, ["light.driveway_lights"]}},
        {"the garage", :control, :sensitive},
        {"all the lights in the kitchen", :control, {:ids, ["light.all_kitchen_lights"]}},
        # A word the name doesn't account for means Henry asks, never acts on a near-miss.
        {"guest bedroom closet light", :control, :ambiguous},
        {"upstairs living room thermostat", :control, :not_ok},
        {"garage homelab music lights", :control, :not_ok},
        {"office lights", :control, :not_ok},
        {"the thermostat", :control, {:ids, ["climate.living_room_thermostat"]}},
        {"the bedroom thermostat", :control, {:ambiguous, ["climate.living_room_thermostat"]}},
        {"the front door lock", :control, :sensitive_some},
        {"unlock the front door", :control, :sensitive_some},
        {"the garage door", :control, :sensitive_some},
        {"the alarm", :control, :sensitive},
        {"the garage door", :status, :one},
        {"front door lock", :status, :one},
        {"Arbol MaXtreme", :control, {:ids, ["media_player.arbol_maxtreme_2"]}},
        {"light.hall_nightlight", :control, {:one, :entity_id}},
        {"light.not_a_thing", :control, :none},
        {"zorblax", :control, :none},
        # A room with no lights of its own is a "did you mean" on its own words, never on "room".
        {"the dining room", :control, {:close_without, "climate.living_room_thermostat"}},
        # A phrase of nothing but house words is the house: lights only for control.
        {"the whole house", :control, :house_lights},
        {"house", :control, :house_lights},
        {"all the lights at home", :control, :house_lights},
        {"everything at home", :control, :house_lights},
        {"the house", :status, :house_everything},
        # Speaker / TV type words: one entity of the type covering every other word acts.
        {"kitchen speaker", :control, {:ids, ["media_player.sonos_kitchen"]}},
        {"the basement speaker", :control, {:ids, ["media_player.sonos_basement"]}},
        {"the tv", :status, {:ids, ["media_player.vizio_tv_3965_television"]}},
        {"the speakers", :control, :ambiguous},
        # Media actions (:media) land on media players only — a room never fans out to lights.
        {"kitchen speaker", :media, {:ids, ["media_player.sonos_kitchen"]}},
        {"kitchen", :media, {:ids, ["media_player.sonos_kitchen"]}},
        {"the basement", :media, {:ids, ["media_player.sonos_basement"]}},
        {"sonos", :media, :ambiguous_media},
        # Nothing playing in the snapshot: "the music" is no one, and never the music-sync lights.
        {"the music", :media, :none},
        # Whole words, never substrings: "it" is inside "kitchen" but names nothing.
        {"it", :media, :none},
        # A clearly named non-player passes through, so the tool can say it can't do that.
        {"the gaming lights", :media, {:ids, ["light.gaming_room_lights"]}},
        {"unlock the front door", :media, :sensitive_some},
        {"media_player.sonos_kitchen", :media, {:one, :entity_id}}
      ] do
    @phrase phrase
    @mode mode
    @expect expect
    test "#{inspect(phrase)} (#{mode})", %{dir: dir} do
      check(Resolve.resolve(dir, @phrase, @mode), @expect)
    end
  end

  test "an alias resolves as an alias" do
    dir =
      Directory.build(
        HomeFixture.with_alias("light.pantry_lighy", "snack closet light"),
        ~U[2026-10-19 20:00:00Z]
      )

    assert {:ok, es, :alias} = Resolve.resolve(dir, "snack closet light", :control)
    assert ids(es) == ["light.pantry_lighy"]
  end

  describe "\"the music\" (:media)" do
    defp with_states(dir, states) do
      Enum.reduce(states, dir, fn {id, state}, d ->
        Directory.put_state(d, id, %{Directory.state(d, id) | "state" => state})
      end)
    end

    test "acts on the one player that's playing", %{dir: dir} do
      dir = with_states(dir, [{"media_player.sonos_kitchen", "playing"}])

      for phrase <- ["the music", "music", "this song", "it"] do
        assert {:ok, [e], :playing} = Resolve.resolve(dir, phrase, :media)
        assert e.entity_id == "media_player.sonos_kitchen"
      end
    end

    test "two playing is a question, not a guess", %{dir: dir} do
      dir =
        with_states(dir, [
          {"media_player.sonos_kitchen", "playing"},
          {"media_player.sonos_basement", "playing"}
        ])

      refute match?({:ok, _, _}, Resolve.resolve(dir, "the music", :media))
    end

    test "nothing playing: the one that's paused (\"resume the music\")", %{dir: dir} do
      dir = with_states(dir, [{"media_player.sonos_basement", "paused"}])
      assert {:ok, [e], :playing} = Resolve.resolve(dir, "the music", :media)
      assert e.entity_id == "media_player.sonos_basement"
    end
  end

  describe "normalizing and near-misses" do
    test "case, punctuation, articles, plurals and nightlight" do
      assert Resolve.tokens("The Pantry Lights!") == ["pantry", "light"]
      assert Resolve.tokens("my Hall nightlight, please") == ["hall", "night", "light"]
      assert Resolve.tokens("David’s MacBook") == ["david", "macbook"]
      assert Resolve.tokens("glass fans") == ["glass", "fan"]
    end

    test "one-character typos only on words of 4+ letters" do
      assert Resolve.near?("lighy", "light")
      assert Resolve.near?("nigh", "night")
      refute Resolve.near?("fan", "fin")
      refute Resolve.near?("light", "lit")
      refute Resolve.near?("gaming", "game")
      refute Resolve.near?("light", "light")
    end

    test "the score is the mean of both coverages; a typo pair counts 0.75" do
      assert Resolve.score(~w(night light), ~w(night light)) == {1.0, []}
      assert Resolve.score(~w(pantry light), ~w(pantry lighy)) == {0.875, []}
      assert {_, ["zorblax"]} = Resolve.score(~w(zorblax light), ~w(hall night light))
    end
  end

  defp check(result, {:ids, want}) do
    assert {:ok, es, _how} = result
    assert ids(es) == want
  end

  defp check(result, {:one, how}), do: assert({:ok, [_], ^how} = result)
  defp check(result, :one), do: assert({:ok, [_], _how} = result)

  defp check(result, :basement_lights) do
    assert {:ok, es, _how} = result
    assert es != []
    assert Enum.all?(es, &(&1.domain == "light"))
    assert "light.basement_lights" in ids(es) or "light.0xb0ce181403681fa2" in ids(es)
  end

  defp check(result, :house_lights) do
    assert {:ok, es, :house} = result
    assert Enum.all?(es, &(&1.domain == "light"))
    assert "light.gaming_room_lights" in ids(es)
    assert "light.hall_nightlight" in ids(es)
    # A member of an included group is dropped: the group already covers it.
    refute "light.gaming_room_light_1" in ids(es)
  end

  defp check(result, :house_everything) do
    assert {:ok, es, :house} = result
    assert "light.gaming_room_lights" in ids(es)
    assert "switch.fireplace_switch" in ids(es)
  end

  defp check(result, {:close_without, id}) do
    assert {:none, close} = result
    assert close != []
    refute id in ids(close)
  end

  defp check(result, :ambiguous_media) do
    assert {:ambiguous, [_, _ | _] = es} = result
    assert Enum.all?(es, &(&1.domain == "media_player"))
  end

  defp check(result, {:which_room, rooms}), do: assert({:which_room, ^rooms} = result)
  defp check(result, :ambiguous), do: assert({:ambiguous, [_ | _]} = result)

  defp check(result, :not_ok), do: refute(match?({:ok, _, _}, result))

  defp check(result, {:ambiguous, want}) do
    assert {:ambiguous, es} = result
    assert ids(es) == want
  end

  defp check(result, :sensitive_some) do
    assert {:sensitive, es} = result
    assert es != []
  end

  defp check(result, :sensitive), do: assert({:sensitive, _} = result)
  defp check(result, :none), do: assert({:none, _} = result)
end
