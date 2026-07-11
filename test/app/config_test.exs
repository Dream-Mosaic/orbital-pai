defmodule App.ConfigTest do
  use ExUnit.Case, async: true
  alias App.Config

  test "default/0 has distinct thinking per tier and sane audio defaults" do
    c = Config.default()
    assert c.reflex_thinking == "minimal"
    assert c.brain_thinking == "low"
    assert c.stt_sample_rate == 16_000
    assert c.stt_model == "ink-2"
    assert c.eager_reflex == true
    # tts_sample_rate is a user-tuned dial (16k/24k/44.1k) — assert sane, don't pin a value.
    assert is_integer(c.tts_sample_rate) and c.tts_sample_rate >= 16_000
  end

  test "default/0 carries tool config: enabled list, timezone, home location" do
    c = Config.default()
    assert is_list(c.tools)
    assert c.timezone == "America/Chicago"
    assert {lat, lon, "Belleville, IL"} = c.weather_home
    assert is_number(lat) and is_number(lon)
  end

  test "default/0 enables the Weather and Reminders tools" do
    tools = Config.default().tools
    assert App.Tools.Weather in tools
    assert App.Tools.Reminders in tools
  end

  describe "vision flag" do
    test "default/0 enables vision by default" do
      assert Config.default().vision == true
    end

    test "default/0 reads the vision override from app env" do
      Application.put_env(:app, :vision, false)
      on_exit(fn -> Application.delete_env(:app, :vision) end)
      assert Config.default().vision == false
    end
  end
end
