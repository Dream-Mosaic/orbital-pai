defmodule App.ToolkitsTest do
  use ExUnit.Case, async: false

  alias App.{Config, Toolkits}
  alias App.Toolkits.Home
  alias App.Test.HomeFixture

  setup do
    Application.put_env(:app, :home_assistant, %{url: "https://ha.example.test", token: "tok"})
    Application.put_env(:app, :home_assistant_directory, HomeFixture.directory())

    on_exit(fn ->
      Application.delete_env(:app, :home_assistant)
      Application.delete_env(:app, :home_assistant_directory)
    end)

    {:ok, cfg: Config.default(), now: ~U[2026-10-19 20:00:00Z]}
  end

  test "catalog line lists the enabled kits", %{cfg: cfg} do
    line = Toolkits.catalog_line(cfg)
    assert line =~ "use_toolkit"
    assert line =~ "home (the house:"
    assert String.ends_with?(line, ".")
  end

  test "catalog line is empty and nothing is advertised when unconfigured" do
    Application.delete_env(:app, :home_assistant)
    cfg = Config.default()
    assert Toolkits.catalog_line(cfg) == ""
    refute App.Tools.UseToolkit in cfg.tools

    assert {:error, :unknown_tool} =
             App.Tools.execute("home_status", %{}, %{session_id: "t", config: cfg})
  end

  describe "preselect" do
    test "generic vocabulary", %{cfg: cfg, now: now} do
      assert Toolkits.preselect(cfg, "turn on the gaming lights", %{}, now) == [Home]
    end

    test "directory names with generic tails stripped", %{cfg: cfg, now: now} do
      assert Toolkits.preselect(cfg, "kill the dining table", %{}, now) == [Home]
    end

    test "unrelated text", %{cfg: cfg, now: now} do
      assert Toolkits.preselect(cfg, "what's the weather tomorrow", %{}, now) == []
    end

    test "follow-up within 10 minutes uses the recent turn", %{cfg: cfg, now: now} do
      recent = fn secs ->
        %{
          recent: [
            %{user_text: "turn on the gaming lights", inserted_at: DateTime.add(now, -secs)}
          ]
        }
      end

      assert Toolkits.preselect(cfg, "make them blue", recent.(60), now) == [Home]
      assert Toolkits.preselect(cfg, "make them blue", recent.(1800), now) == []
    end

    test "an already-open kit is skipped", %{cfg: cfg, now: now} do
      cfg = Toolkits.open(cfg, [Home])
      assert Toolkits.preselect(cfg, "turn on the gaming lights", %{}, now) == []
    end
  end

  test "open/2 is idempotent and open?/2 holds", %{cfg: cfg} do
    once = Toolkits.open(cfg, [Home])
    twice = Toolkits.open(once, [Home])
    assert once == twice
    assert Toolkits.open?(twice, "home")
    refute Toolkits.open?(cfg, "home")
    assert App.Tools.HomeAssistant in twice.tools
  end

  test "find is case-insensitive and among enabled kits", %{cfg: cfg} do
    assert Toolkits.find(cfg, "Home") == Home
    assert Toolkits.find(cfg, "nope") == nil
  end

  test "guidance_note" do
    assert Toolkits.guidance_note([]) == ""
    assert Toolkits.guidance_note([Home]) =~ ~r/\A\(Toolkit open: home\. /
  end

  test "an unopened kit's tools still dispatch, but are not declared", %{cfg: cfg} do
    refute Enum.any?(
             hd(App.Tools.declarations(cfg)).functionDeclarations,
             &(&1.name == "home_control")
           )

    assert {:ok, _} =
             App.Tools.execute("home_status", %{"targets" => ["fireplace"]}, %{
               session_id: "t",
               config: cfg
             })
  end
end
