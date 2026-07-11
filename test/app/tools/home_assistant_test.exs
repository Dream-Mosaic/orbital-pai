defmodule App.Tools.HomeAssistantTest do
  use ExUnit.Case, async: false

  alias App.Tools.HomeAssistant, as: Tool

  # async: false — mutates global app env (:home_assistant + req opts).

  @ctx %{session_id: "test", config: App.Config.default()}

  setup do
    Application.put_env(:app, :home_assistant, %{
      url: "https://ha.example.test",
      token: "test-token"
    })

    Application.put_env(:app, :home_assistant_req_opts, plug: {Req.Test, HaToolStub})

    on_exit(fn ->
      Application.delete_env(:app, :home_assistant)
      Application.delete_env(:app, :home_assistant_req_opts)
    end)

    :ok
  end

  defp stub_states(entities) do
    Req.Test.stub(HaToolStub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/states"} -> Req.Test.json(conn, entities)
        other -> flunk("unexpected request: #{inspect(other)}")
      end
    end)
  end

  @raw [
    %{
      "entity_id" => "light.kitchen",
      "state" => "on",
      "attributes" => %{"friendly_name" => "Kitchen Light", "brightness" => 255}
    },
    %{
      "entity_id" => "lock.front_door",
      "state" => "locked",
      "attributes" => %{"friendly_name" => "Front Door"}
    },
    %{"entity_id" => "sun.sun", "state" => "above_horizon", "attributes" => %{}}
  ]

  test "declarations include home_state with an optional query" do
    decls = Tool.declarations()
    hs = Enum.find(decls, &(&1.name == "home_state"))
    assert hs
    assert hs.parameters.required == []
    assert Map.has_key?(hs.parameters.properties, :query)
  end

  test "home_state returns the compacted view (noise dropped, sensitive included)" do
    stub_states(@raw)

    assert {:ok, %{entities: entities, count: 2}} = Tool.execute("home_state", %{}, @ctx)
    assert Enum.map(entities, & &1.entity_id) == ["light.kitchen", "lock.front_door"]
    assert %{name: "Kitchen Light", brightness_pct: 100} = hd(entities)
  end

  test "home_state applies the query filter and notes an empty result" do
    stub_states(@raw)

    assert {:ok, %{entities: [%{entity_id: "light.kitchen"}], count: 1}} =
             Tool.execute("home_state", %{"query" => "kitchen"}, @ctx)

    assert {:ok, %{entities: [], note: note}} =
             Tool.execute("home_state", %{"query" => "sauna"}, @ctx)

    assert note =~ "no matching"
  end

  test "home_state flattens an unreachable hub to a relayable error note" do
    Req.Test.stub(HaToolStub, fn conn -> Req.Test.transport_error(conn, :timeout) end)
    assert {:ok, %{error: err}} = Tool.execute("home_state", %{}, @ctx)
    assert err =~ "home hub"
  end

  test "home_state caches for ~10s and normalizes the query cache key" do
    assert Tool.cache_ttl("home_state") == 10_000

    assert Tool.cache_key("home_state", %{"query" => "  Kitchen "}) ==
             Tool.cache_key("home_state", %{"query" => "kitchen"})

    assert Tool.cache_key("home_state", %{}) == Tool.cache_key("home_state", %{"query" => nil})
  end

  test "home_state has bridge phrases" do
    assert Tool.bridge("home_state") != []
  end
end
