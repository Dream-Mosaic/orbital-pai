defmodule App.Tools.UseToolkitTest do
  use ExUnit.Case, async: false

  alias App.{Config, Toolkits}

  setup do
    Application.put_env(:app, :home_assistant, %{url: "https://ha.example.test", token: "tok"})
    on_exit(fn -> Application.delete_env(:app, :home_assistant) end)
    {:ok, cfg: Config.default()}
  end

  test "declares use_toolkit with a required name" do
    [d] = App.Tools.UseToolkit.declarations()
    assert d.name == "use_toolkit"
    assert d.parameters.required == ["name"]
  end

  test "opens a kit", %{cfg: cfg} do
    assert {:ok, %{opened: "home", guidance: g, tools: tools}} =
             App.Tools.execute("use_toolkit", %{"name" => "Home"}, %{session_id: "t", config: cfg})

    assert g == App.Toolkits.Home.guidance()
    assert "home_control" in tools
  end

  test "already open", %{cfg: cfg} do
    cfg = Toolkits.open(cfg, [App.Toolkits.Home])

    assert {:ok, %{already_open: "home"}} =
             App.Tools.UseToolkit.execute("use_toolkit", %{"name" => "home"}, %{config: cfg})
  end

  test "unknown or missing name", %{cfg: cfg} do
    assert {:ok, %{note: ~s(no toolkit called "garage"), toolkits: ["home"]}} =
             App.Tools.UseToolkit.execute("use_toolkit", %{"name" => "garage"}, %{config: cfg})

    assert {:ok, %{note: ~s(no toolkit called ""), toolkits: ["home"]}} =
             App.Tools.UseToolkit.execute("use_toolkit", %{}, %{config: cfg})
  end

  test "is read-only" do
    assert App.Tools.read_only?("use_toolkit")
  end
end
