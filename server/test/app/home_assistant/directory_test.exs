defmodule App.HomeAssistant.DirectoryTest do
  use ExUnit.Case, async: false

  alias App.HomeAssistant.{Directory, Entities}
  alias App.Test.HomeFixture

  setup do
    on_exit(fn ->
      Application.delete_env(:app, :home_assistant_directory)
    end)

    %{dir: HomeFixture.directory()}
  end

  defp ids(dir), do: dir |> Directory.entries() |> MapSet.new(& &1.entity_id)

  test "a light group is in view with its members", %{dir: dir} do
    e = Directory.get(dir, "light.gaming_room_lights")
    assert e.group?
    assert e.members == ["light.gaming_room_light_1", "light.gaming_room_light_2"]
    assert e.area == nil
    assert e.name == "Gaming lights"
    assert e.class == :controllable
  end

  test "registry area and name", %{dir: dir} do
    e = Directory.get(dir, "switch.fireplace_switch")
    assert e.area == "Living Room"
    assert e.name == "Fireplace Switch"
  end

  test "input_boolean is controllable", %{dir: dir} do
    assert Directory.get(dir, "input_boolean.night_lights").class == :controllable
    assert Entities.classify(%{"entity_id" => "input_boolean.x"}) == :controllable
  end

  test "area is inherited from the device when the entity has none", %{dir: dir} do
    assert Directory.get(dir, "light.0xb0ce181403681fa2").area == "Basement"
  end

  test "locks and garage covers are sensitive read-only", %{dir: dir} do
    assert Directory.get(dir, "lock.u_bolt_pro_z_wave_smart_lock").class == :sensitive_read_only

    assert Directory.get(dir, "cover.smart_garage_door_opener_msg100_main_channel").class ==
             :sensitive_read_only
  end

  test "segments, categorized, unexposed and ignored entities are out of view", %{dir: dir} do
    in_view = ids(dir)
    refute "light.govee_mantle_strip_segment_001" in in_view
    refute "switch.apollo_air_1_2c77c8_prevent_sleep" in in_view
    refute "media_player.office" in in_view
    refute Enum.any?(in_view, &String.starts_with?(&1, "update."))
  end

  test "exposure unknown: everything non-hidden is in view" do
    dir = Directory.build(%{HomeFixture.payloads() | exposed: nil}, ~U[2026-10-19 20:00:00Z])
    refute dir.exposure_known?
    assert "media_player.office" in ids(dir)
    assert HomeFixture.directory().exposure_known?
  end

  test "an unregistered but exposed state is in view", %{dir: dir} do
    assert Directory.get(dir, "switch.100205ecea").class == :controllable
  end

  test "put_state replaces and removes states", %{dir: dir} do
    id = "switch.fireplace_switch"
    raw = %{"entity_id" => id, "state" => "on", "attributes" => %{}}
    assert Directory.state(Directory.put_state(dir, id, raw), id)["state"] == "on"
    gone = Directory.put_state(dir, id, nil)
    refute id in ids(gone)
    assert Directory.state(gone, id) == nil
  end

  test "areas are sorted names", %{dir: dir} do
    assert "Game Room" in dir.areas and "Basement" in dir.areas
    assert dir.areas == Enum.sort(dir.areas)
  end

  test "with_alias adds a trimmed alias" do
    dir =
      Directory.build(
        HomeFixture.with_alias("switch.fireplace_switch", " hearth "),
        DateTime.utc_now()
      )

    assert "hearth" in Directory.get(dir, "switch.fireplace_switch").aliases
  end

  test "set_connected", %{dir: dir} do
    assert dir.connected?
    refute Directory.set_connected(dir, false).connected?
  end

  describe "App.HomeAssistant.directory/0" do
    test "the app env wins", %{dir: dir} do
      Application.put_env(:app, :home_assistant_directory, dir)
      assert {:ok, ^dir} = App.HomeAssistant.directory()
      Application.put_env(:app, :home_assistant_directory, fn -> {:error, :not_loaded} end)
      assert {:error, :not_loaded} = App.HomeAssistant.directory()
    end

    test "unconfigured" do
      prev = Application.get_env(:app, :home_assistant)
      Application.delete_env(:app, :home_assistant)
      on_exit(fn -> if prev, do: Application.put_env(:app, :home_assistant, prev) end)
      assert {:error, :not_configured} = App.HomeAssistant.directory()
    end
  end
end
