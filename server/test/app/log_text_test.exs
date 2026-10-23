defmodule App.LogTextTest do
  # async: false — flips app env (and the global Logger level) for the duration of a test.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias App.Config
  alias App.LogText
  alias App.Test.Fakes.CacheTool

  setup do
    prev = Application.fetch_env(:app, :log_speech)
    level = Logger.level()
    App.Tools.Cache.clear()

    on_exit(fn ->
      case prev do
        {:ok, v} -> Application.put_env(:app, :log_speech, v)
        :error -> Application.delete_env(:app, :log_speech)
      end

      Logger.configure(level: level)
    end)

    :ok
  end

  test "unset means verbatim: the same text inspect gives, quotes included" do
    Application.delete_env(:app, :log_speech)
    assert LogText.said("hello") == ~s("hello")
    assert LogText.said(%{"q" => "x"}) == inspect(%{"q" => "x"})
  end

  test "log_speech: false logs only the length, counting graphemes" do
    Application.put_env(:app, :log_speech, false)
    assert LogText.said("hello") == "‹5 chars›"
    assert LogText.said("héllo") == "‹5 chars›"
    assert LogText.said(~s(éllo)) == "‹4 chars›"
  end

  test "log_speech: false redacts anything that is not a string" do
    Application.put_env(:app, :log_speech, false)
    assert LogText.said(%{"q" => "secret"}) == "‹redacted›"
  end

  test "a converted call site (tool-cache hit) redacts in the real log line" do
    Logger.configure(level: :info)
    Application.put_env(:app, :log_speech, false)
    ctx = %{session_id: "default", config: %Config{tools: [CacheTool]}}
    args = %{"query" => "my secret plans"}

    {:ok, _} = App.Tools.execute("cached_read", args, ctx)

    log =
      capture_log([level: :info], fn -> {:ok, _} = App.Tools.execute("cached_read", args, ctx) end)

    assert log =~ "[tool-cache] hit cached_read"
    assert log =~ "‹redacted›"
    refute log =~ "secret plans"
  end
end
