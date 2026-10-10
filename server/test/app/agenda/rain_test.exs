defmodule App.Agenda.RainTest do
  # async: false — the producer is a separate process sharing the sandbox, and one test sets the
  # global Req test plug through application env.
  use App.DataCase, async: false

  import ExUnit.CaptureLog

  alias App.Agenda.{Item, Rain}
  alias App.Config
  alias App.Users

  @tz "America/Chicago"

  # 17:05 UTC = 12:05 CDT: comfortably outside quiet hours. The slot covering it is 17:00–17:15.
  @now ~U[2026-10-10 17:05:00Z]
  @base ~U[2026-10-10 17:00:00Z]

  # A forecast of 15-minute slots from `base` (the slot covering now), one per mm value; a
  # `{mm, prob}` tuple sets the probability too. Slots carry their INTERVAL START (`at`).
  defp forecast(values, base \\ @base) do
    values
    |> Enum.with_index()
    |> Enum.map(fn {v, i} ->
      {mm, prob} = if is_tuple(v), do: v, else: {v, nil}
      %{at: DateTime.add(base, i * 15 * 60, :second), mm: mm, prob: prob}
    end)
  end

  defp min(n), do: n * 60

  defp decide(slots, now, state \\ Rain.initial_state()), do: Rain.decide(slots, now, state, @tz)

  describe "decide/4 — when rain starts" do
    test "dry now, wet from a slot 25 minutes out → alert, with the predicted start remembered" do
      assert {:alert, 25, state} = decide(forecast([0.0, 0.0, 0.4, 0.6]), @now)
      assert state.rain_at == ~U[2026-10-10 17:30:00Z]
      assert state.alerts == [@now]
    end

    test "minutes round to the nearest 5" do
      slots = forecast([0.0, 0.0, 0.4])
      # 17:30 start: 22.5 min → 25, 22 min → 20, 18 min → 20, 17 min → 15
      assert {:alert, 25, _} = decide(slots, DateTime.add(@base, min(7) + 30, :second))
      assert {:alert, 20, _} = decide(slots, DateTime.add(@base, min(8), :second))
      assert {:alert, 20, _} = decide(slots, DateTime.add(@base, min(12), :second))
      assert {:alert, 15, _} = decide(slots, DateTime.add(@base, min(13), :second))
    end

    test "0.1 mm is wet; just under it is dry" do
      assert {:alert, _, _} = decide(forecast([0.0, 0.0, 0.1]), @now)
      assert {:quiet, _} = decide(forecast([0.0, 0.0, 0.09]), @now)
    end

    test "a precipitation probability of 60% or more counts as wet" do
      assert {:alert, 25, _} = decide(forecast([{0.0, 10}, {0.0, 30}, {0.0, 60}]), @now)
      assert {:quiet, _} = decide(forecast([{0.0, 10}, {0.0, 30}, {0.0, 59}]), @now)
    end

    test "missing values read as dry" do
      assert {:quiet, _} = decide(forecast([nil, nil, {nil, nil}]), @now)
    end

    test "the window is 15 to 45 minutes, inclusive" do
      # wet from 17:30
      slots = forecast([0.0, 0.0, 0.5])
      assert {:alert, 15, _} = decide(slots, ~U[2026-10-10 17:15:00Z])
      assert {:quiet, _} = decide(slots, ~U[2026-10-10 17:15:01Z])

      # wet from 17:45
      slots = forecast([0.0, 0.0, 0.0, 0.0, 0.5], ~U[2026-10-10 16:45:00Z])
      assert {:alert, 45, _} = decide(slots, ~U[2026-10-10 17:00:00Z])
      assert {:quiet, _} = decide(slots, ~U[2026-10-10 16:59:59Z])
    end

    test "too soon (under 15 minutes) → quiet" do
      assert {:quiet, state} = decide(forecast([0.0, 0.4]), @now)
      assert state.alerts == []
      assert state.rain_at == nil
    end

    test "too far (over 45 minutes) → quiet" do
      assert {:quiet, _} = decide(forecast([0.0, 0.0, 0.0, 0.0, 0.5]), @now)
    end

    test "nothing wet ahead → quiet" do
      assert {:quiet, state} = decide(forecast([0.0, 0.0, 0.0, 0.0, 0.0]), @now)
      assert state == Rain.initial_state()
    end

    test "no slot covering now (a stale or empty forecast) → quiet" do
      assert {:quiet, _} = decide([], @now)
      later = DateTime.add(@base, 3600, :second)
      assert {:quiet, _} = decide(forecast([0.0, 0.5], later), @now)
    end

    test "slots arrive in any order" do
      assert {:alert, 25, _} = decide(Enum.reverse(forecast([0.0, 0.0, 0.4])), @now)
    end
  end

  describe "decide/4 — one alert per rain event" do
    test "already raining → quiet, and a pause-then-resume inside 2 hours stays quiet" do
      assert {:quiet, state} = decide(forecast([0.8, 0.5, 0.0]), @now)
      # wet through the end of the current slot
      assert state.last_wet_at == ~U[2026-10-10 17:15:00Z]

      # 40 minutes later it's dry, and more rain is 20 minutes out: same event, no alert.
      later = ~U[2026-10-10 17:45:00Z]
      assert {:quiet, _} = decide(forecast([0.0, 0.0, 0.7], later), later, state)
    end

    test "the next poll doesn't re-alert the same event, even if its start drifts" do
      assert {:alert, 25, state} = decide(forecast([0.0, 0.0, 0.4]), @now)

      ten_later = DateTime.add(@now, min(10), :second)
      assert {:quiet, state} = decide(forecast([0.0, 0.0, 0.4]), ten_later, state)

      # The model pushes the start back: still the event already announced.
      assert {:quiet, _} = decide(forecast([0.0, 0.0, 0.0, 0.4]), ten_later, state)
    end

    test "re-arms only after 2 hours dry" do
      assert {:alert, 25, state} = decide(forecast([0.0, 0.0, 0.4]), @now)

      # It rains 17:30–18:15; a poll at 18:05 sees the current slot (18:00–18:15) wet.
      at_1805 = ~U[2026-10-10 18:05:00Z]

      assert {:quiet, state} =
               decide(forecast([0.6, 0.0], ~U[2026-10-10 18:00:00Z]), at_1805, state)

      assert state.last_wet_at == ~U[2026-10-10 18:15:00Z]

      # 1h55 after the last wet slot ended: a new shower 25 minutes out is still the same event.
      at_2010 = ~U[2026-10-10 20:10:00Z]
      base = ~U[2026-10-10 20:00:00Z]
      assert {:quiet, state} = decide(forecast([0.0, 0.0, 0.0, 0.5], base), at_2010, state)

      # 2h05 dry: re-armed.
      at_2020 = ~U[2026-10-10 20:20:00Z]
      base = ~U[2026-10-10 20:15:00Z]
      assert {:alert, 25, _} = decide(forecast([0.0, 0.0, 0.5], base), at_2020, state)
    end

    test "a forecast rain that never came re-arms 2 hours after its predicted start" do
      assert {:alert, 25, state} = decide(forecast([0.0, 0.0, 0.4]), @now)
      # predicted 17:30; nothing observed since
      base = ~U[2026-10-10 19:15:00Z]
      at_1920 = ~U[2026-10-10 19:20:00Z]
      assert {:quiet, state} = decide(forecast([0.0, 0.0, 0.5], base), at_1920, state)

      base = ~U[2026-10-10 19:30:00Z]
      at_1935 = ~U[2026-10-10 19:35:00Z]
      assert {:alert, 25, _} = decide(forecast([0.0, 0.0, 0.5], base), at_1935, state)
    end

    test "rain in the forecast's recent past counts as observed (no alert mid-event)" do
      # The hour before now (16:00–17:00) was wet, though no poll saw it: same event.
      slots = forecast([0.5, 0.4, 0.0, 0.0, 0.0, 0.0, 0.3], ~U[2026-10-10 16:00:00Z])
      assert {:quiet, state} = decide(slots, @now)
      assert state.last_wet_at == ~U[2026-10-10 16:30:00Z]
    end
  end

  describe "decide/4 — daily cap and quiet hours (local time)" do
    # A forecast whose current slot covers `now` and whose rain starts 25 minutes after `now`
    # rounded down to its quarter hour — i.e. dry, dry, wet from the slot after next.
    defp rain_soon(now) do
      base = %{now | minute: div(now.minute, 15) * 15, second: 0, microsecond: {0, 0}}
      forecast([0.0, 0.0, 0.5], base)
    end

    defp alert_at(now, state) do
      assert {:alert, _, state} = decide(rain_soon(now), now, state)
      state
    end

    test "at most 3 alerts per LOCAL day (the UTC date rolls over at 19:00 CDT)" do
      # 12:05, 14:35, 17:05 CDT — each 2.5h apart, so each is a fresh event.
      state =
        Rain.initial_state()
        |> then(&alert_at(~U[2026-10-10 17:05:00Z], &1))
        |> then(&alert_at(~U[2026-10-10 19:35:00Z], &1))
        |> then(&alert_at(~U[2026-10-10 22:05:00Z], &1))

      # 19:35 CDT is still Oct 10 locally, though it's Oct 11 in UTC: capped.
      fourth = ~U[2026-10-11 00:35:00Z]
      assert {:quiet, state} = decide(rain_soon(fourth), fourth, state)

      # The next local morning resets the count.
      next_day = ~U[2026-10-11 13:05:00Z]
      assert {:alert, _, state} = decide(rain_soon(next_day), next_day, state)
      # yesterday's alerts are no longer carried
      assert state.alerts == [next_day]
    end

    test "quiet between 22:00 and 07:00 local" do
      # 22:05 CDT
      assert {:quiet, _} = decide(rain_soon(~U[2026-10-11 03:05:00Z]), ~U[2026-10-11 03:05:00Z])
      # 03:00 CDT
      assert {:quiet, _} = decide(rain_soon(~U[2026-10-11 08:00:00Z]), ~U[2026-10-11 08:00:00Z])
      # 06:59 CDT
      assert {:quiet, _} = decide(rain_soon(~U[2026-10-11 11:59:00Z]), ~U[2026-10-11 11:59:00Z])
      # 07:00 CDT
      assert {:alert, _, _} =
               decide(rain_soon(~U[2026-10-11 12:00:00Z]), ~U[2026-10-11 12:00:00Z])

      # 21:59 CDT
      assert {:alert, _, _} =
               decide(rain_soon(~U[2026-10-11 02:59:00Z]), ~U[2026-10-11 02:59:00Z])
    end

    test "a quiet-hours rain doesn't consume the event: it's just not announced" do
      at = ~U[2026-10-11 03:05:00Z]
      assert {:quiet, state} = decide(rain_soon(at), at, Rain.initial_state())
      assert state.alerts == []
      assert state.rain_at == nil
    end

    test "DST-safe: the fall-back morning (2026-11-01) uses CST, not CDT" do
      # 12:30 UTC is 06:30 CST — quiet. A fixed CDT offset would call it 07:30 and speak.
      assert {:quiet, _} = decide(rain_soon(~U[2026-11-01 12:30:00Z]), ~U[2026-11-01 12:30:00Z])
      # 13:00 UTC is 07:00 CST.
      assert {:alert, _, _} =
               decide(rain_soon(~U[2026-11-01 13:00:00Z]), ~U[2026-11-01 13:00:00Z])
    end

    test "DST-safe: the spring-forward morning (2027-03-14) uses CDT, not CST" do
      # 12:30 UTC is 07:30 CDT — speak. A fixed CST offset would call it 06:30 and stay quiet.
      assert {:alert, _, _} =
               decide(rain_soon(~U[2027-03-14 12:30:00Z]), ~U[2027-03-14 12:30:00Z])

      # 11:30 UTC is 06:30 CDT.
      assert {:quiet, _} = decide(rain_soon(~U[2027-03-14 11:30:00Z]), ~U[2027-03-14 11:30:00Z])
    end
  end

  describe "slots/1 (Open-Meteo minutely_15, pure)" do
    test "each value is the PRECEDING 15 minutes' sum, so a slot starts 15 minutes before its label" do
      body = %{
        "minutely_15" => %{
          "time" => [1_791_651_600, 1_791_652_500],
          "precipitation" => [0.0, 0.4],
          "precipitation_probability" => [5, 70]
        }
      }

      assert Rain.slots(body) == [
               %{at: DateTime.from_unix!(1_791_651_600 - 900), mm: 0.0, prob: 5},
               %{at: DateTime.from_unix!(1_791_652_500 - 900), mm: 0.4, prob: 70}
             ]
    end

    test "a missing probability series reads as nil, not a crash" do
      body = %{"minutely_15" => %{"time" => [1_791_651_600], "precipitation" => [0.2]}}
      assert [%{mm: 0.2, prob: nil}] = Rain.slots(body)
    end

    test "anything else is no slots" do
      assert Rain.slots(%{"error" => true}) == []
      assert Rain.slots(nil) == []
      assert Rain.slots(%{"minutely_15" => %{"time" => ["2026-10-10T17:00"]}}) == []
    end
  end

  describe "the spoken item" do
    test "is a canned heads-up that expires when the rain is due" do
      start = ~U[2026-10-10 17:30:00Z]
      item = Rain.item(25, start)

      assert %Item{} = item
      assert item.kind == :heads_up
      assert item.canned == true
      assert item.deliver == :when_idle
      assert item.prompt == "Rain's starting in about 25 minutes."
      assert item.lead_idle == "Heads up —"
      assert item.lead_interjected == "Oh — quick heads up —"
      assert item.persist_as == nil
      assert item.expires_at == start
    end
  end

  describe "fetch/1 (Open-Meteo)" do
    test "asks for 15-minute precipitation at home and parses the slots" do
      Application.put_env(:app, :weather_req_opts, plug: {Req.Test, RainStub}, retry: false)
      on_exit(fn -> Application.delete_env(:app, :weather_req_opts) end)
      test_pid = self()

      Req.Test.stub(RainStub, fn conn ->
        send(test_pid, {:query, conn.query_params})

        Req.Test.json(conn, %{
          "minutely_15" => %{
            "time" => [1_791_651_600],
            "precipitation" => [0.3],
            "precipitation_probability" => [40]
          }
        })
      end)

      assert {:ok, [%{mm: 0.3, prob: 40}]} = Rain.fetch({38.52, -89.98, "Belleville, IL"})
      assert_received {:query, q}
      assert q["latitude"] == "38.52"
      assert q["longitude"] == "-89.98"
      assert q["minutely_15"] == "precipitation,precipitation_probability"
      assert q["timeformat"] == "unixtime"
    end

    test "an HTTP error or an empty body is an error" do
      Application.put_env(:app, :weather_req_opts, plug: {Req.Test, RainStub}, retry: false)
      on_exit(fn -> Application.delete_env(:app, :weather_req_opts) end)

      Req.Test.stub(RainStub, fn conn -> Plug.Conn.send_resp(conn, 400, "{\"error\":true}") end)
      assert {:error, {:http, 400}} = Rain.fetch({38.52, -89.98, "Belleville, IL"})

      Req.Test.stub(RainStub, fn conn -> Req.Test.json(conn, %{}) end)
      assert {:error, :no_data} = Rain.fetch({38.52, -89.98, "Belleville, IL"})
    end
  end

  # ---- the producer ----

  describe "polling and delivery" do
    setup do
      Application.put_env(:app, :allowed_users, [
        %{email: "a@x.com", name: "Alice"},
        %{email: "b@x.com", name: "Bob"}
      ])

      {:ok, alice} = Users.upsert_allowed("a@x.com")
      {:ok, bob} = Users.upsert_allowed("b@x.com")
      forward_agenda(alice.id)
      forward_agenda(bob.id)
      on_exit(fn -> Application.delete_env(:app, :allowed_users) end)

      {:ok, clock} = Agent.start_link(fn -> @now end)
      {:ok, weather} = Agent.start_link(fn -> {:ok, forecast([0.0, 0.0, 0.4, 0.6])} end)

      %{alice: alice, bob: bob, clock: clock, weather: weather}
    end

    # Relays `uid`'s agenda topic to the test as `{:agenda_for, uid, item}`, so WHO was told is
    # observable (the broadcast itself doesn't say).
    defp forward_agenda(uid) do
      test_pid = self()

      spawn_link(fn ->
        Phoenix.PubSub.subscribe(App.PubSub, "agenda:#{uid}")
        send(test_pid, {:subscribed, uid})
        relay(test_pid, uid)
      end)

      assert_receive {:subscribed, ^uid}
    end

    defp relay(test_pid, uid) do
      receive do
        {:agenda_due, item} -> send(test_pid, {:agenda_for, uid, item})
      end

      relay(test_pid, uid)
    end

    # No automatic polling; tests drive it with Rain.poll/1. Every fetch is reported.
    defp start_rain(ctx, opts \\ []) do
      test_pid = self()
      weather = ctx.weather

      start_supervised!(
        {Rain,
         name: nil,
         poll_ms: nil,
         tz: @tz,
         now: fn -> Agent.get(ctx.clock, & &1) end,
         config: %Config{weather_home: {1.5, 2.5, "Home"}},
         fetch: fn home ->
           send(test_pid, {:fetched, home})

           case Agent.get(weather, & &1) do
             :raise -> raise "boom"
             result -> result
           end
         end,
         listening?: Keyword.get(opts, :listening, fn _uid -> true end)}
      )
    end

    test "rain 25 minutes out → every listening heads-up user hears it, once", ctx do
      pid = start_rain(ctx)

      :ok = Rain.poll(pid)
      assert_received {:fetched, {1.5, 2.5, "Home"}}

      for uid <- [ctx.alice.id, ctx.bob.id] do
        assert_receive {:agenda_for, ^uid, %Item{kind: :heads_up, canned: true} = item}
        assert item.prompt == "Rain's starting in about 25 minutes."
        assert item.expires_at == ~U[2026-10-10 17:30:00Z]
      end

      # Ten minutes on, same forecast: already announced.
      Agent.update(ctx.clock, &DateTime.add(&1, 600, :second))
      :ok = Rain.poll(pid)
      assert_received {:fetched, _}
      refute_receive {:agenda_for, _, _}
    end

    test "nobody listening → no forecast fetched at all", ctx do
      pid = start_rain(ctx, listening: fn _ -> false end)

      :ok = Rain.poll(pid)
      refute_received {:fetched, _}
      refute_receive {:agenda_for, _, _}
    end

    test "the pref off → that user is neither a reason to fetch nor told", ctx do
      {:ok, _} = Users.update_prefs(ctx.alice, %{heads_up: false})
      alice_id = ctx.alice.id
      bob_id = ctx.bob.id

      # Only Alice is around, and she's switched heads-ups off: no fetch.
      pid = start_rain(ctx, listening: fn uid -> uid == alice_id end)
      :ok = Rain.poll(pid)
      refute_received {:fetched, _}

      # Both around: Bob alone hears it.
      stop_supervised!(Rain)
      pid = start_rain(ctx)
      :ok = Rain.poll(pid)
      assert_received {:fetched, _}
      assert_receive {:agenda_for, ^bob_id, %Item{}}
      refute_receive {:agenda_for, ^alice_id, _}
    end

    test "a user with no device isn't told; the one listening is", ctx do
      alice_id = ctx.alice.id
      bob_id = ctx.bob.id
      pid = start_rain(ctx, listening: fn uid -> uid == bob_id end)

      :ok = Rain.poll(pid)
      assert_receive {:agenda_for, ^bob_id, %Item{}}
      refute_receive {:agenda_for, ^alice_id, _}
    end

    @tag :capture_log
    test "one user's presence check crashing doesn't cost the other their heads-up", ctx do
      alice_id = ctx.alice.id
      bob_id = ctx.bob.id

      pid =
        start_rain(ctx,
          listening: fn
            ^bob_id -> raise "presence down"
            _ -> true
          end
        )

      :ok = Rain.poll(pid)
      assert_receive {:agenda_for, ^alice_id, %Item{}}
      refute_receive {:agenda_for, ^bob_id, _}
    end

    test "a failed fetch is logged and skipped; the next poll still works", ctx do
      Agent.update(ctx.weather, fn _ -> {:error, :timeout} end)
      pid = start_rain(ctx)

      log = capture_log([level: :warning], fn -> :ok = Rain.poll(pid) end)

      assert log =~ "[rain]"
      assert log =~ "timeout"
      refute_receive {:agenda_for, _, _}
      assert Process.alive?(pid)

      Agent.update(ctx.weather, fn _ -> {:ok, forecast([0.0, 0.0, 0.4])} end)
      :ok = Rain.poll(pid)
      assert_receive {:agenda_for, _, %Item{prompt: "Rain's starting in about 25 minutes."}}
    end

    test "a crashing fetcher is logged and doesn't take the producer down", ctx do
      Agent.update(ctx.weather, fn _ -> :raise end)
      pid = start_rain(ctx)

      log = capture_log(fn -> :ok = Rain.poll(pid) end)
      assert log =~ "[rain]"
      assert log =~ "boom"
      assert Process.alive?(pid)
      refute_receive {:agenda_for, _, _}
    end
  end
end
