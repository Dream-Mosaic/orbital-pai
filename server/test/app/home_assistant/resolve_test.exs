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
        {"the lights", :control, {:which_room, "Basement"}},
        {"office lights", :control, :not_ok},
        {"the thermostat", :control, {:ids, ["climate.living_room_thermostat"]}},
        {"the bedroom thermostat", :control, {:ambiguous, ["climate.living_room_thermostat"]}},
        {"the front door lock", :control, :sensitive_some},
        {"the garage door", :control, :sensitive_some},
        {"the alarm", :control, :sensitive},
        {"the garage door", :status, :one},
        {"front door lock", :status, :one},
        {"Arbol MaXtreme", :control, {:ids, ["media_player.arbol_maxtreme_2"]}},
        {"light.hall_nightlight", :control, {:one, :entity_id}},
        {"light.not_a_thing", :control, :none},
        {"zorblax", :control, :none}
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

  defp check(result, {:which_room, room}) do
    assert {:which_room, rooms} = result
    assert room in rooms
  end

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
