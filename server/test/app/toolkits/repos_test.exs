defmodule App.Toolkits.ReposTest do
  use ExUnit.Case, async: false

  alias App.{Config, Toolkits}
  alias App.Dispatch.Board
  alias App.Toolkits.Repos

  @fixture "test/fixtures/dispatch/boards.json" |> File.read!() |> Jason.decode!()

  @guidance "You can see David's forge (code.clausens.cloud) and start Claude Code on its issues. " <>
              "Use code_board to see what's open — speak a short list (number, a few words each), " <>
              "candidates first, and say when a repo has no CLAUDE.md. Before start_claude, read " <>
              "back exactly which issues you'll start and wait for a yes. Pass anything extra " <>
              "David says as notes. Claude works unattended on a branch and opens a PR (or a " <>
              "draft, or asks a question on the issue); nothing merges without David. Use " <>
              "claude_jobs for \"how's Claude doing\". file_issue creates an issue — read the " <>
              "title back first. For a design-gated repo, a feature issue becomes a design-doc " <>
              "PR, not code — say so."

  setup do
    Application.put_env(:app, :forge, %{
      url: "https://forge.test",
      token: "t",
      dispatch_repo: "kalcode/claude-dispatch"
    })

    Application.put_env(:app, :dispatch_req_opts, plug: {Req.Test, ForgeStub})
    Board.forget()

    on_exit(fn ->
      Application.delete_env(:app, :forge)
      Application.delete_env(:app, :dispatch_req_opts)
      Board.forget()
    end)

    {:ok, cfg: Config.default(), now: ~U[2026-10-21 20:00:00Z]}
  end

  # Reports every forge request to the test; answers /user/repos from the fixture.
  defp forge_repos do
    test = self()

    Req.Test.stub(ForgeStub, fn conn ->
      send(test, {:forge, conn.request_path})
      Req.Test.json(conn, @fixture["repos"])
    end)
  end

  test "id, summary, tools and the guidance copy" do
    assert Repos.id() == "repos"

    assert Repos.summary() ==
             "your code: the issue boards on your forge, and starting Claude Code on an issue"

    assert Repos.tools() == [App.Tools.ClaudeDispatch]
    assert Repos.guidance() == @guidance
  end

  test "the default config carries the kit; it is enabled only when the forge is configured",
       %{cfg: cfg} do
    assert Repos in Config.default().toolkits
    assert Repos in Toolkits.enabled(cfg)
    assert App.Tools.UseToolkit in cfg.tools
    assert Toolkits.catalog_line(cfg) =~ "repos (your code: the issue boards on your forge"

    Application.delete_env(:app, :forge)
    refute Repos.enabled?(Config.default())
    refute Repos in Toolkits.enabled(Config.default())

    Application.put_env(:app, :forge, %{url: "https://forge.test", token: ""})
    refute Repos.enabled?(Config.default())
  end

  describe "preselect" do
    test "\"what could Claude work on today\" opens the kit", %{cfg: cfg, now: now} do
      assert Toolkits.preselect(cfg, "what could Claude work on today", %{}, now) == [Repos]
    end

    test "the weather does not", %{cfg: cfg, now: now} do
      assert Toolkits.preselect(cfg, "what's the weather", %{}, now) == []
    end

    for text <- [
          "anything on the board",
          "file an issue for that",
          "is there a PR for it",
          "any bugs in the tracker app",
          "open a pull request",
          "check the forge"
        ] do
      @text text
      test "vocabulary: #{inspect(text)}", %{cfg: cfg, now: now} do
        assert Toolkits.preselect(cfg, @text, %{}, now) == [Repos]
      end
    end

    test "a repo name preselects once a board read has published the names",
         %{cfg: cfg, now: now} do
      assert Board.phrases() == []
      assert Toolkits.preselect(cfg, "chronicles thirty one", %{}, now) == []

      forge_repos()
      assert {:ok, _} = Board.repos()

      assert Toolkits.preselect(cfg, "chronicles thirty one", %{}, now) == [Repos]
      assert Toolkits.preselect(cfg, "how's the unwritten chronicles going", %{}, now) == [Repos]
      assert Toolkits.preselect(cfg, "what's the weather", %{}, now) == []
    end

    test "pronoun and wake-name aliases are not topic words", %{cfg: cfg, now: now} do
      forge_repos()
      assert {:ok, _} = Board.repos()

      # "you" and "Henry" resolve to personal-assistant, but they are in nearly every turn.
      assert Toolkits.preselect(cfg, "Henry, can you set a timer", %{}, now) == []
    end

    test "wants? makes no forge call" do
      forge_repos()
      assert {:ok, _} = Board.repos()
      assert_received {:forge, "/api/v1/user/repos"}

      assert Repos.wants?("chronicles thirty one", %{})
      refute Repos.wants?("what's the weather", %{})
      refute_received {:forge, _}
    end
  end

  test "names are published once per changed repo list (cached for 10 minutes)" do
    forge_repos()
    assert {:ok, repos} = Board.repos()
    assert {:ok, ^repos} = Board.repos()
    assert_received {:forge, "/api/v1/user/repos"}
    refute_received {:forge, _}

    phrases = Board.phrases()
    assert "unwritten chronicles" in phrases
    assert "chronicles" in phrases
    refute "you" in phrases
    refute "henry" in phrases
  end
end
