defmodule App.ConfigTimezoneTest do
  # Mutates the global :app/:timezone env, so it must NOT run concurrently with the async
  # tests that read Config.default()/Config.timezone.
  use ExUnit.Case, async: false
  alias App.Config

  setup do
    original = Application.get_env(:app, :timezone)

    on_exit(fn ->
      if original,
        do: Application.put_env(:app, :timezone, original),
        else: Application.delete_env(:app, :timezone)
    end)

    :ok
  end

  test "timezone/0 uses a valid configured IANA zone (the TIMEZONE env override)" do
    Application.put_env(:app, :timezone, "America/New_York")
    assert Config.timezone() == "America/New_York"
    # default/0 threads the resolved zone into the per-conversation config the brain grounds on.
    assert Config.default().timezone == "America/New_York"
  end

  test "timezone/0 falls back to America/Chicago on an invalid zone (a typo can't crash shift_zone!)" do
    Application.put_env(:app, :timezone, "Not/AZone")
    assert Config.timezone() == "America/Chicago"
    assert Config.default().timezone == "America/Chicago"
  end
end
