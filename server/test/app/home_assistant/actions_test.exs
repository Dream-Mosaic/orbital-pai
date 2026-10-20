defmodule App.HomeAssistant.ActionsTest do
  use ExUnit.Case, async: false

  alias App.HomeAssistant.{Actions, Directory}
  alias App.Test.HomeFixture

  @garage "cover.smart_garage_door_opener_msg100_main_channel"
  @lock "lock.u_bolt_pro_z_wave_smart_lock"

  setup_all do
    dir = HomeFixture.directory()
    s = &Directory.state(dir, &1)

    %{
      gaming: s.("light.gaming_room_lights"),
      hall: s.("light.hall_nightlight"),
      pantry: s.("light.pantry_lighy"),
      night: s.("input_boolean.night_lights"),
      garage: s.(@garage),
      lock: s.(@lock)
    }
  end

  test "actions/0 is the closed vocabulary" do
    assert Actions.actions() ==
             ~w(on off toggle set_brightness brighten dim set_color set_color_temp set_effect set_temperature set_position open close set_speed volume_set play pause next activate)
  end

  test "set_color by name, case and whitespace tolerant", %{gaming: g} do
    ok = {:ok, {"light", "turn_on", %{rgb_color: [0, 0, 255]}}}
    assert Actions.plan(g, "set_color", %{color: "blue"}) == ok
    assert Actions.plan(g, "set_color", %{color: "Blue"}) == ok
    assert Actions.plan(g, "set_color", %{color: " Blue "}) == ok

    assert {:ok, {_, _, %{rgb_color: [255, 190, 110]}}} =
             Actions.plan(g, "set_color", %{color: "warm white"})
  end

  test "set_color by hex", %{gaming: g} do
    for c <- ["#FF8800", "#f80", "ff8800"] do
      assert Actions.plan(g, "set_color", %{color: c}) ==
               {:ok, {"light", "turn_on", %{rgb_color: [255, 136, 0]}}}
    end
  end

  test "set_color errors", %{gaming: g, pantry: p, garage: gar} do
    assert Actions.plan(g, "set_color", %{color: "chartreuse-ish"}) ==
             {:error, {:unknown_color, "chartreuse-ish"}}

    assert Actions.plan(g, "set_color", %{}) == {:error, :needs_value}
    assert Actions.plan(p, "set_color", %{color: "red"}) == {:error, :no_color_support}
    assert Actions.plan(gar, "set_color", %{color: "red"}) == {:error, :not_controllable}
  end

  test "every named color resolves", %{gaming: g} do
    for c <-
          ~w(red orange yellow green blue purple pink white cyan teal magenta lavender gold lime amber) ++
            ["warm white"] do
      assert {:ok, _} = Actions.plan(g, "set_color", %{color: c})
    end
  end

  test "set_color_temp by word and by kelvin, clamped", %{gaming: g} do
    assert Actions.plan(g, "set_color_temp", %{color: "warm"}) ==
             {:ok, {"light", "turn_on", %{color_temp_kelvin: 2700}}}

    assert {:ok, {_, _, %{color_temp_kelvin: 6493}}} =
             Actions.plan(g, "set_color_temp", %{value: 9000})

    assert {:ok, {_, _, %{color_temp_kelvin: 2000}}} =
             Actions.plan(g, "set_color_temp", %{value: 1000})

    assert {:ok, {_, _, %{color_temp_kelvin: 4000}}} =
             Actions.plan(g, "set_color_temp", %{color: " Neutral "})

    assert Actions.plan(g, "set_color_temp", %{}) == {:error, :needs_value}
  end

  test "set_color_temp needs color_temp mode", %{hall: h} do
    assert Actions.plan(h, "set_color_temp", %{color: "warm"}) == {:error, :no_color_temp_support}
  end

  test "set_effect", %{hall: h, gaming: g} do
    assert Actions.plan(h, "set_effect", %{effect: "color loop"}) ==
             {:ok, {"light", "turn_on", %{effect: "colorloop"}}}

    assert Actions.plan(h, "set_effect", %{effect: "ColorLoop"}) ==
             {:ok, {"light", "turn_on", %{effect: "colorloop"}}}

    assert {:error, {:unknown_effect, list}} = Actions.plan(h, "set_effect", %{effect: "disco"})
    assert "colorloop" in list
    assert Actions.plan(g, "set_effect", %{effect: "x"}) == {:error, :no_effects}
  end

  test "delegated actions and the new Entities rows", %{
    night: n,
    gaming: g,
    lock: l,
    garage: gar
  } do
    assert Actions.plan(n, "on", %{}) == {:ok, {"input_boolean", "turn_on", %{}}}
    assert Actions.plan(n, "off", %{}) == {:ok, {"input_boolean", "turn_off", %{}}}
    assert Actions.plan(n, "toggle", %{}) == {:ok, {"input_boolean", "toggle", %{}}}
    assert {:ok, {_, _, %{brightness_step_pct: 20}}} = Actions.plan(g, "brighten", %{})
    assert {:ok, {_, _, %{brightness_step_pct: -30}}} = Actions.plan(g, "dim", %{value: 30})
    assert {:ok, {_, _, %{brightness_step_pct: 100}}} = Actions.plan(g, "brighten", %{value: 500})
    assert {:ok, {_, _, %{brightness_pct: 50}}} = Actions.plan(g, "set_brightness", %{value: 50})
    assert Actions.plan(g, "bogus", %{}) == {:error, :unknown_action}
    assert Actions.plan(l, "on", %{}) == {:error, :not_controllable}
    assert Actions.plan(gar, "open", %{}) == {:error, :not_controllable}
  end

  test "cover open/close map for non-garage covers" do
    cover = %{"entity_id" => "cover.blinds", "state" => "closed", "attributes" => %{}}
    assert Actions.plan(cover, "open", %{}) == {:ok, {"cover", "open_cover", %{}}}
    assert Actions.plan(cover, "close", %{}) == {:ok, {"cover", "close_cover", %{}}}
  end

  test "string values from the model are tolerated", %{gaming: g} do
    assert {:ok, {_, _, %{brightness_pct: 50}}} =
             Actions.plan(g, "set_brightness", %{value: "50"})

    assert {:ok, {_, _, %{brightness_step_pct: -10}}} = Actions.plan(g, "dim", %{value: "10"})
  end
end
