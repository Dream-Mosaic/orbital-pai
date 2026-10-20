defmodule App.HomeAssistant.SocketTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  require Logger

  alias App.HomeAssistant.{Directory, Socket}
  alias App.Test.HomeFixture

  @now ~U[2026-10-19 20:00:00Z]
  @later ~U[2026-10-19 20:00:01.250Z]

  @load_types ~w(config/area_registry/list config/device_registry/list config/entity_registry/list
                 homeassistant/expose_entity/list get_states)
  @registry_types ~w(config/area_registry/list config/device_registry/list
                     config/entity_registry/list homeassistant/expose_entity/list)

  # -- helpers: drive the machine the way the live client does --

  defp authed do
    s = Socket.new("secret-token")
    {s, _} = Socket.handle(s, %{"type" => "auth_required", "ha_version" => "2026.8.0"}, @now)
    {s, out} = Socket.handle(s, %{"type" => "auth_ok", "ha_version" => "2026.8.0"}, @now)
    {s, out}
  end

  defp result(id, payload),
    do: %{"id" => id, "type" => "result", "success" => true, "result" => payload}

  defp failed(id),
    do: %{
      "id" => id,
      "type" => "result",
      "success" => false,
      "error" => %{"code" => "unauthorized", "message" => "Unauthorized"}
    }

  defp payload_for("config/area_registry/list", p), do: p.areas
  defp payload_for("config/device_registry/list", p), do: p.devices
  defp payload_for("config/entity_registry/list", p), do: p.entities
  defp payload_for("homeassistant/expose_entity/list", p), do: %{"exposed_entities" => p.exposed}
  defp payload_for("get_states", p), do: p.states

  # Answer every load command in `out` from `payloads` (optionally failing some types).
  defp answer(s, out, payloads, opts \\ []) do
    fail = Keyword.get(opts, :fail, [])

    out
    |> Enum.filter(&(&1.type in @load_types))
    |> Enum.reduce(s, fn %{id: id, type: type}, s ->
      msg = if type in fail, do: failed(id), else: result(id, payload_for(type, payloads))
      {s, _} = Socket.handle(s, msg, @later)
      s
    end)
  end

  defp loaded do
    {s, out} = authed()
    {answer(s, out, HomeFixture.payloads()), out}
  end

  defp sub_id(out, event_type),
    do:
      Enum.find_value(
        out,
        &((&1.type == "subscribe_events" and &1.event_type == event_type) && &1.id)
      )

  defp event(id, event_type, data),
    do: %{"id" => id, "type" => "event", "event" => %{"event_type" => event_type, "data" => data}}

  defp state_changed(id, entity_id, new_state),
    do: event(id, "state_changed", %{"entity_id" => entity_id, "new_state" => new_state})

  # The test config logs at :warning; the load/connect lines are :info.
  defp capture_info(fun) do
    prev = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log(fun)
    after
      Logger.configure(level: prev)
    end
  end

  defp raw(entity_id, state, attrs \\ %{}),
    do: %{"entity_id" => entity_id, "state" => state, "attributes" => attrs}

  # -- the handshake --

  test "auth_required sends exactly one auth message carrying the token" do
    {s, out} = Socket.handle(Socket.new("secret-token"), %{"type" => "auth_required"}, @now)
    assert out == [%{type: "auth", access_token: "secret-token"}]
    assert s.phase == :authenticating
  end

  test "auth_ok requests the five loads and the four subscriptions with increasing ids" do
    {s, out} = authed()
    assert s.phase == :loading
    assert s.ha_version == "2026.8.0"

    ids = Enum.map(out, & &1.id)
    assert ids == Enum.sort(ids)
    assert ids == Enum.uniq(ids)
    assert Enum.all?(ids, &(is_integer(&1) and &1 > 0))

    types = Enum.map(out, & &1.type)
    # the brief's order: three registries, exposure, states, then the subscriptions
    assert Enum.take(types, 5) == @load_types

    subs = for %{type: "subscribe_events", event_type: et} <- out, do: et

    assert Enum.sort(subs) ==
             Enum.sort(~w(state_changed area_registry_updated device_registry_updated
                       entity_registry_updated))
  end

  test "the token never shows up in inspect output" do
    refute inspect(Socket.new("secret-token")) =~ "secret-token"
  end

  test "the auth message is the only place the token goes" do
    {_s, out} = authed()
    refute inspect(out) =~ "secret-token"
  end

  # -- loading --

  test "no directory until every load has answered" do
    {s, out} = authed()
    [first | _] = out
    {s, []} = Socket.handle(s, result(first.id, HomeFixture.payloads().areas), @later)
    assert Socket.directory(s) == nil
  end

  test "the five load results build the directory" do
    log = capture_info(fn -> send(self(), {:loaded, loaded()}) end)
    assert_received {:loaded, {s, _out}}

    assert %Directory{} = dir = Socket.directory(s)
    assert Directory.get(dir, "light.gaming_room_lights")
    assert dir.exposure_known?
    assert dir.connected?
    assert dir.loaded_at == @later
    assert s.phase == :ready

    n = length(Directory.entries(dir))
    assert log =~ "[home] directory loaded: #{n} in view, 12 areas in 1250ms"
  end

  test "results arrive in any order" do
    {s, out} = authed()
    s = answer(s, Enum.reverse(out), HomeFixture.payloads())
    assert Directory.get(Socket.directory(s), "switch.fireplace_switch")
  end

  test "a refused exposure list loads with exposure unknown, and says so once" do
    {s, out} = authed()

    log =
      capture_log(fn ->
        s = answer(s, out, HomeFixture.payloads(), fail: ["homeassistant/expose_entity/list"])
        send(self(), {:s, s})
      end)

    assert_received {:s, s}
    dir = Socket.directory(s)
    refute dir.exposure_known?
    # unknown exposure: every non-hidden entity counts as exposed, so an unexposed one is in view
    assert Directory.get(dir, "media_player.office")

    assert log =~
             "[home] exposure list refused — treating every non-hidden entity as exposed"

    # the backstop refresh, refused again, does not repeat the warning
    {s, out} = Socket.refresh(s)

    log =
      capture_log(fn ->
        answer(s, out, HomeFixture.payloads(), fail: ["homeassistant/expose_entity/list"])
      end)

    refute log =~ "exposure list refused"
  end

  @tag capture_log: true
  test "an exposure result without the exposed_entities key counts as unknown" do
    {s, out} = authed()

    s =
      Enum.reduce(out, s, fn
        %{type: "homeassistant/expose_entity/list", id: id}, s ->
          {s, _} = Socket.handle(s, result(id, %{}), @later)
          s

        %{type: t} = cmd, s when t in @load_types ->
          answer(s, [cmd], HomeFixture.payloads())

        _, s ->
          s
      end)

    refute Socket.directory(s).exposure_known?
  end

  # -- state events --

  test "state_changed replaces the entity's state" do
    {s, out} = loaded()
    sid = sub_id(out, "state_changed")

    {s, []} =
      Socket.handle(
        s,
        state_changed(sid, "switch.fireplace_switch", raw("switch.fireplace_switch", "on")),
        @later
      )

    assert Directory.state(Socket.directory(s), "switch.fireplace_switch")["state"] == "on"
  end

  test "state_changed for an entity the directory never saw is kept" do
    {s, out} = loaded()
    sid = sub_id(out, "state_changed")

    {s, []} =
      Socket.handle(
        s,
        state_changed(sid, "light.brand_new", raw("light.brand_new", "off")),
        @later
      )

    assert Directory.state(Socket.directory(s), "light.brand_new")["state"] == "off"
  end

  test "state_changed with new_state null removes the state" do
    {s, out} = loaded()
    sid = sub_id(out, "state_changed")
    {s, []} = Socket.handle(s, state_changed(sid, "switch.fireplace_switch", nil), @later)
    assert Directory.state(Socket.directory(s), "switch.fireplace_switch") == nil
  end

  test "a state_changed that lands while the first load is still in flight is not lost" do
    {s, out} = authed()
    sid = sub_id(out, "state_changed")
    states = Enum.find(out, &(&1.type == "get_states"))
    rest = Enum.reject(out, &(&1.type == "get_states"))

    {s, _} = Socket.handle(s, result(states.id, HomeFixture.payloads().states), @later)

    {s, []} =
      Socket.handle(
        s,
        state_changed(sid, "switch.fireplace_switch", raw("switch.fireplace_switch", "on")),
        @later
      )

    s = answer(s, rest, HomeFixture.payloads())
    assert Directory.state(Socket.directory(s), "switch.fireplace_switch")["state"] == "on"
  end

  test "events for ids we never subscribed are ignored" do
    {s, _out} = loaded()
    before = Socket.directory(s)
    {s, []} = Socket.handle(s, state_changed(9_999, "switch.fireplace_switch", nil), @later)
    assert Socket.directory(s) == before
  end

  # -- registry updates --

  test "a registry update re-requests the registries and exposure, then rebuilds keeping states" do
    {s, out} = loaded()
    sid = sub_id(out, "state_changed")
    rid = sub_id(out, "entity_registry_updated")
    last_id = out |> Enum.map(& &1.id) |> Enum.max()

    {s, []} =
      Socket.handle(
        s,
        state_changed(sid, "switch.fireplace_switch", raw("switch.fireplace_switch", "on")),
        @later
      )

    {s, reload} =
      Socket.handle(s, event(rid, "entity_registry_updated", %{"action" => "update"}), @later)

    assert Enum.map(reload, & &1.type) |> Enum.sort() == Enum.sort(@registry_types)
    assert Enum.all?(reload, &(&1.id > last_id))
    refute Enum.any?(reload, &(&1.type == "get_states"))

    s = answer(s, reload, HomeFixture.with_alias("light.pantry_lighy", "pantry light"))
    dir = Socket.directory(s)

    assert "pantry light" in Directory.get(dir, "light.pantry_lighy").aliases
    assert Directory.state(dir, "switch.fireplace_switch")["state"] == "on"
    assert s.phase == :ready
  end

  test "a second registry update while a reload is in flight coalesces into one follow-up" do
    {s, out} = loaded()
    aid = sub_id(out, "area_registry_updated")
    did = sub_id(out, "device_registry_updated")

    {s, first} = Socket.handle(s, event(aid, "area_registry_updated", %{}), @later)
    assert length(first) == 4

    # the second event, mid-reload: nothing new goes out yet
    {s, []} = Socket.handle(s, event(did, "device_registry_updated", %{}), @later)
    {s, []} = Socket.handle(s, event(did, "device_registry_updated", %{}), @later)

    # the first set answering rebuilds and sends exactly one follow-up set
    p = HomeFixture.payloads()
    {s, follow_up} = answer_collecting(s, first, p)
    assert Socket.directory(s)
    assert Enum.map(follow_up, & &1.type) |> Enum.sort() == Enum.sort(@registry_types)
    first_max = first |> Enum.map(& &1.id) |> Enum.max()
    assert Enum.all?(follow_up, &(&1.id > first_max))

    # the follow-up answering (with an alias) rebuilds again and asks for nothing more
    {s, more} =
      answer_collecting(s, follow_up, HomeFixture.with_alias("light.pantry_lighy", "pantry"))

    assert more == []
    assert "pantry" in Directory.get(Socket.directory(s), "light.pantry_lighy").aliases
  end

  defp answer_collecting(s, cmds, payloads) do
    Enum.reduce(cmds, {s, []}, fn %{id: id, type: type}, {s, acc} ->
      {s, out} = Socket.handle(s, result(id, payload_for(type, payloads)), @later)
      {s, acc ++ out}
    end)
  end

  test "a registry update during the first load is applied after it" do
    {s, out} = authed()
    eid = sub_id(out, "entity_registry_updated")
    {s, []} = Socket.handle(s, event(eid, "entity_registry_updated", %{}), @later)

    {s, follow_up} =
      answer_collecting(s, Enum.filter(out, &(&1.type in @load_types)), HomeFixture.payloads())

    assert Socket.directory(s)
    assert Enum.map(follow_up, & &1.type) |> Enum.sort() == Enum.sort(@registry_types)
  end

  test "refresh re-requests the registries plus exposure, and does nothing before the first load" do
    {s, _} = authed()
    assert {_, []} = Socket.refresh(s)

    {s, _} = loaded()
    {_s, out} = Socket.refresh(s)
    assert Enum.map(out, & &1.type) |> Enum.sort() == Enum.sort(@registry_types)
  end

  # -- failures and noise --

  test "auth_invalid marks the socket auth_failed and sends nothing" do
    s = Socket.new("secret-token")
    {s, _} = Socket.handle(s, %{"type" => "auth_required"}, @now)

    log =
      capture_log(fn ->
        send(
          self(),
          {:r, Socket.handle(s, %{"type" => "auth_invalid", "message" => "bad"}, @now)}
        )
      end)

    assert_received {:r, {s, []}}
    assert s.phase == :auth_failed
    assert log =~ "[home] socket auth refused — HOME_ASSISTANT_TOKEN needs attention"
    refute log =~ "secret-token"
  end

  test "unknown ids and unknown message types are ignored" do
    {s, _} = loaded()
    assert {^s, []} = Socket.handle(s, result(9_999, []), @later)
    assert {^s, []} = Socket.handle(s, %{"type" => "pong", "id" => 3}, @later)
    assert {^s, []} = Socket.handle(s, %{"type" => "something_new"}, @later)
    assert {^s, []} = Socket.handle(s, %{"no" => "type"}, @later)
  end

  test "a malformed state_changed does not crash" do
    {s, out} = loaded()
    sid = sub_id(out, "state_changed")
    assert {_, []} = Socket.handle(s, event(sid, "state_changed", %{"entity_id" => 7}), @later)

    assert {_, []} =
             Socket.handle(
               s,
               event(sid, "state_changed", %{"entity_id" => "x.y", "new_state" => "on"}),
               @later
             )
  end

  # -- disconnect, backoff, ping --

  test "disconnected keeps the directory, marks it disconnected and restarts the ids" do
    {s, _} = loaded()
    s = Socket.disconnected(s)
    assert s.phase == :connecting
    dir = Socket.directory(s)
    refute dir.connected?
    assert Directory.get(dir, "light.gaming_room_lights")

    # a fresh connection: ids start over, and the reload brings connected? back
    {s, _} = Socket.handle(s, %{"type" => "auth_required"}, @now)
    {s, out} = Socket.handle(s, %{"type" => "auth_ok", "ha_version" => "2026.8.0"}, @now)
    assert hd(out).id == 1
    refute Socket.directory(s).connected?
    s = answer(s, out, HomeFixture.payloads())
    assert Socket.directory(s).connected?
  end

  test "retry delays back off 1, 2, 5, 15, 30, 60 s and cap; a refused token waits 10 min" do
    s = Socket.new("t")
    assert Enum.map(0..7, &Socket.retry_delay_s(s, &1)) == [1, 2, 5, 15, 30, 60, 60, 60]
    assert Socket.retry_delay_s(%{s | phase: :auth_failed}, 0) == 600
    assert Socket.disconnected(%{s | phase: :auth_failed}).phase == :auth_failed
  end

  test "ping only once authenticated, with a fresh id" do
    assert {_, []} = Socket.ping(Socket.new("t"))
    {s, out} = loaded()
    {_s, [ping]} = Socket.ping(s)
    assert ping.type == "ping"
    assert ping.id > out |> Enum.map(& &1.id) |> Enum.max()
  end

  # -- the read seam with no live process --

  describe "App.HomeAssistant.directory/0 without the live client" do
    setup do
      prev = Application.get_env(:app, :home_assistant)
      Application.put_env(:app, :home_assistant, %{url: "https://ha.example", token: "t"})
      Application.delete_env(:app, :home_assistant_directory)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:app, :home_assistant, prev),
          else: Application.delete_env(:app, :home_assistant)
      end)
    end

    test "is not loaded" do
      refute Process.whereis(App.HomeAssistant.Live)
      assert {:error, :not_loaded} = App.HomeAssistant.directory()
    end
  end
end
