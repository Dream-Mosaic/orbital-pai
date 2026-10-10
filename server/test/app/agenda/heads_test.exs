defmodule App.Agenda.HeadsTest do
  # async: false — the producer is a separate process sharing the sandbox, the calendar tool runs
  # under the global App.Conversations.TaskSup, and the fake calendar reads :persistent_term.
  use App.DataCase, async: false

  alias App.Agenda.{Heads, Item}
  alias App.Config
  alias App.Users

  # A fixed instant. The producer's clock is injected, so a nudge armed for `start - 10 min`
  # fires after a REAL delay of (start - 10 min - @now) — events placed a few hundred ms past
  # the lead line fire almost at once, while the spoken minutes stay exact.
  @now ~U[2026-10-10 19:00:00Z]

  defmodule FakeCalendar do
    @behaviour App.Tools.Tool
    def declarations,
      do: [%{name: "get_calendar_events", description: "c", parameters: %{type: "object"}}]

    # Events per user id; every fetch is reported to the test so "no API call" is observable.
    def execute("get_calendar_events", args, %{user_id: uid}) do
      if pid = :persistent_term.get({__MODULE__, :observer}, nil),
        do: send(pid, {:calendar_fetched, uid, args})

      case :persistent_term.get({__MODULE__, :mode}, :ok) do
        :ok ->
          events = :persistent_term.get({__MODULE__, :events}, %{}) |> Map.get(uid, [])
          {:ok, %{events: events, errors: [], accounts_read: ["Personal"]}}

        :down ->
          {:error, :timeout}
      end
    end
  end

  setup do
    Application.put_env(:app, :allowed_users, [
      %{email: "a@x.com", name: "Alice"},
      %{email: "b@x.com", name: "Bob"}
    ])

    {:ok, alice} = Users.upsert_allowed("a@x.com")
    {:ok, bob} = Users.upsert_allowed("b@x.com")
    Phoenix.PubSub.subscribe(App.PubSub, "agenda:#{alice.id}")
    Phoenix.PubSub.subscribe(App.PubSub, "agenda:#{bob.id}")
    :persistent_term.put({FakeCalendar, :observer}, self())

    on_exit(fn ->
      Application.delete_env(:app, :allowed_users)
      :persistent_term.erase({FakeCalendar, :observer})
      :persistent_term.erase({FakeCalendar, :events})
      :persistent_term.erase({FakeCalendar, :mode})
    end)

    {:ok, clock} = Agent.start_link(fn -> @now end)

    %{
      alice: alice,
      bob: bob,
      clock: clock,
      config: %Config{tools: [FakeCalendar], tool_cache: false}
    }
  end

  defp events!(map), do: :persistent_term.put({FakeCalendar, :events}, map)

  defp event(title, start, extra \\ %{}) do
    Map.merge(
      %{summary: title, start: DateTime.to_iso8601(start), all_day?: false, location: nil},
      extra
    )
  end

  defp at(offset_ms), do: DateTime.add(@now, offset_ms, :millisecond)

  @lead_ms 10 * 60_000

  # Start the producer with no automatic polling; tests drive it with Heads.poll/1.
  defp start_heads(ctx, opts \\ []) do
    listening = Keyword.get(opts, :listening, fn _uid -> true end)

    start_supervised!(
      {Heads,
       name: nil,
       poll_ms: nil,
       now: fn -> Agent.get(ctx.clock, & &1) end,
       config: ctx.config,
       listening?: listening}
    )
  end

  describe "polling and delivery" do
    test "a nudge fires 10 minutes before the event, canned, spoken as 'starts in 10 minutes'",
         ctx do
      start = at(@lead_ms + 150)
      events!(%{ctx.alice.id => [event("Poke the Brain", start)]})
      pid = start_heads(ctx)

      :ok = Heads.poll(pid)
      assert_receive {:calendar_fetched, uid, args}, 500
      assert uid == ctx.alice.id
      assert args["time_min"] == DateTime.to_iso8601(@now)
      assert args["time_max"] == DateTime.to_iso8601(DateTime.add(@now, 40 * 60, :second))

      refute_received {:agenda_due, _}
      assert_receive {:agenda_due, %Item{} = item}, 1_000

      assert item.kind == :heads_up
      assert item.canned == true
      assert item.deliver == :when_idle
      assert item.prompt == "Poke the Brain starts in 10 minutes."
      assert item.lead_idle == "Heads up —"
      assert item.lead_interjected == "Oh — quick heads up —"
      assert item.persist_as == nil
      assert item.expires_at == DateTime.add(start, 120, :second)
    end

    test "an event already inside the lead window nudges now, with the real minutes", ctx do
      events!(%{ctx.alice.id => [event("Standup", at(4 * 60_000))]})
      pid = start_heads(ctx)

      :ok = Heads.poll(pid)
      assert_receive {:agenda_due, %Item{prompt: "Standup starts in 4 minutes."}}, 500
    end

    test "an event that has already started never nudges", ctx do
      events!(%{ctx.alice.id => [event("Already on", at(-60_000))]})
      pid = start_heads(ctx)

      :ok = Heads.poll(pid)
      refute_receive {:agenda_due, _}, 300
    end

    test "all-day events never nudge", ctx do
      events!(%{
        ctx.alice.id => [
          %{summary: "Mom's birthday", start: "2026-10-10", all_day?: true, location: nil}
        ]
      })

      pid = start_heads(ctx)
      :ok = Heads.poll(pid)
      refute_receive {:agenda_due, _}, 300
    end

    test "the location rides along in its short form (before the first comma)", ctx do
      events!(%{
        ctx.alice.id => [
          event("Dentist", at(5 * 60_000), %{location: "1086 Cromwell Ln, Belleville, IL 62220"})
        ]
      })

      pid = start_heads(ctx)
      :ok = Heads.poll(pid)

      assert_receive {:agenda_due,
                      %Item{prompt: "Dentist starts in 5 minutes, at 1086 Cromwell Ln."}},
                     500
    end

    test "re-polls never double-nudge the same event", ctx do
      events!(%{ctx.alice.id => [event("Standup", at(4 * 60_000))]})
      pid = start_heads(ctx)

      :ok = Heads.poll(pid)
      assert_receive {:agenda_due, _}, 500
      :ok = Heads.poll(pid)
      :ok = Heads.poll(pid)
      refute_receive {:agenda_due, _}, 300
    end

    test "re-polls never double-ARM a nudge that hasn't fired yet", ctx do
      events!(%{ctx.alice.id => [event("Review", at(@lead_ms + 300))]})
      pid = start_heads(ctx)

      :ok = Heads.poll(pid)
      :ok = Heads.poll(pid)
      assert_receive {:agenda_due, _}, 1_000
      refute_receive {:agenda_due, _}, 400
    end

    test "the same event on two connected accounts nudges once", ctx do
      start = at(3 * 60_000)

      events!(%{
        ctx.alice.id => [
          event("Family dinner", start, %{account: "Personal"}),
          event("Family dinner", start, %{account: "Work"})
        ]
      })

      pid = start_heads(ctx)
      :ok = Heads.poll(pid)
      assert_receive {:agenda_due, _}, 500
      refute_receive {:agenda_due, _}, 300
    end

    test "keys for events long past are pruned on the next poll", ctx do
      events!(%{ctx.alice.id => [event("Standup", at(4 * 60_000))]})
      pid = start_heads(ctx)

      :ok = Heads.poll(pid)
      assert_receive {:agenda_due, _}, 500
      assert map_size(:sys.get_state(pid).armed) == 1

      # An hour on, the event is over: its dedup key goes (and, having started, it can't re-arm).
      Agent.update(ctx.clock, &DateTime.add(&1, 3600, :second))
      :ok = Heads.poll(pid)
      assert :sys.get_state(pid).armed == %{}
      refute_receive {:agenda_due, _}, 200
    end

    test "a calendar outage at poll time arms nothing and doesn't crash", ctx do
      :persistent_term.put({FakeCalendar, :mode}, :down)
      pid = start_heads(ctx)

      :ok = Heads.poll(pid)
      refute_receive {:agenda_due, _}, 200
      assert Process.alive?(pid)
    end
  end

  describe "who gets polled" do
    test "a user with no connected device is skipped — no calendar call at all", ctx do
      events!(%{
        ctx.alice.id => [event("Alice's thing", at(4 * 60_000))],
        ctx.bob.id => [event("Bob's thing", at(4 * 60_000))]
      })

      alice_id = ctx.alice.id
      pid = start_heads(ctx, listening: fn uid -> uid == alice_id end)

      :ok = Heads.poll(pid)
      assert_receive {:calendar_fetched, ^alice_id, _}, 500
      bob_id = ctx.bob.id
      refute_received {:calendar_fetched, ^bob_id, _}

      assert_receive {:agenda_due, %Item{prompt: "Alice's thing starts in 4 minutes."}}, 500
      refute_receive {:agenda_due, _}, 300
    end

    @tag :capture_log
    test "one user's crash keeps the other's dedup keys (no double nudge on the next poll)",
         ctx do
      events!(%{ctx.alice.id => [event("Standup", at(4 * 60_000))]})
      bob_id = ctx.bob.id

      pid =
        start_heads(ctx,
          listening: fn
            ^bob_id -> raise "presence down"
            _ -> true
          end
        )

      :ok = Heads.poll(pid)
      assert_receive {:agenda_due, %Item{prompt: "Standup starts in 4 minutes."}}, 500
      :ok = Heads.poll(pid)
      refute_receive {:agenda_due, _}, 300
    end

    test "a user with the pref off is skipped — no calendar call at all", ctx do
      {:ok, _} = Users.update_prefs(ctx.alice, %{heads_up: false})
      events!(%{ctx.alice.id => [event("Standup", at(4 * 60_000))]})
      pid = start_heads(ctx, listening: fn uid -> uid == ctx.alice.id end)

      :ok = Heads.poll(pid)
      alice_id = ctx.alice.id
      refute_received {:calendar_fetched, ^alice_id, _}
      refute_receive {:agenda_due, _}, 300
    end
  end

  describe "at fire time" do
    test "the pref switched off after arming → no nudge", ctx do
      events!(%{ctx.alice.id => [event("Review", at(@lead_ms + 200))]})
      pid = start_heads(ctx)

      :ok = Heads.poll(pid)
      {:ok, _} = Users.update_prefs(Users.get(ctx.alice.id), %{heads_up: false})
      refute_receive {:agenda_due, _}, 600
    end

    test "the device gone at fire time → no nudge, and a later poll may arm it again", ctx do
      {:ok, present} = Agent.start_link(fn -> true end)
      events!(%{ctx.alice.id => [event("Review", at(@lead_ms + 200))]})
      pid = start_heads(ctx, listening: fn _uid -> Agent.get(present, & &1) end)

      :ok = Heads.poll(pid)
      Agent.update(present, fn _ -> false end)
      refute_receive {:agenda_due, _}, 600
      assert :sys.get_state(pid).armed == %{}

      # Back three minutes later, still before the start: the next poll nudges inside the window.
      Agent.update(present, fn _ -> true end)
      Agent.update(ctx.clock, &DateTime.add(&1, 3 * 60, :second))
      :ok = Heads.poll(pid)
      assert_receive {:agenda_due, %Item{prompt: "Review starts in 7 minutes."}}, 500
    end

    test "an event cancelled after arming → no nudge", ctx do
      events!(%{ctx.alice.id => [event("Review", at(@lead_ms + 200))]})
      pid = start_heads(ctx)

      :ok = Heads.poll(pid)
      events!(%{ctx.alice.id => []})
      refute_receive {:agenda_due, _}, 600
    end

    test "a calendar outage at fire time still nudges (it was there 5 minutes ago)", ctx do
      events!(%{ctx.alice.id => [event("Review", at(@lead_ms + 200))]})
      pid = start_heads(ctx)

      :ok = Heads.poll(pid)
      :persistent_term.put({FakeCalendar, :mode}, :down)
      assert_receive {:agenda_due, %Item{prompt: "Review starts in 10 minutes."}}, 1_000
    end
  end

  describe "prompt/4 (pure)" do
    @start ~U[2026-10-10 19:10:00Z]

    test "whole minutes, singular and plural" do
      assert Heads.prompt("Poke the Brain", nil, @start, ~U[2026-10-10 19:00:00Z]) ==
               "Poke the Brain starts in 10 minutes."

      assert Heads.prompt("Poke the Brain", nil, @start, ~U[2026-10-10 19:06:50Z]) ==
               "Poke the Brain starts in 3 minutes."

      assert Heads.prompt("Poke the Brain", nil, @start, ~U[2026-10-10 19:09:00Z]) ==
               "Poke the Brain starts in 1 minute."
    end

    test "within half a minute of the start, or past it, is 'starts now'" do
      assert Heads.prompt("Standup", nil, @start, ~U[2026-10-10 19:09:40Z]) ==
               "Standup starts now."

      assert Heads.prompt("Standup", nil, @start, ~U[2026-10-10 19:11:00Z]) ==
               "Standup starts now."
    end

    test "location: short form; blank and URL-like locations are left out" do
      now = ~U[2026-10-10 19:00:00Z]

      assert Heads.prompt("Dentist", "1086 Cromwell Ln, Belleville, IL", @start, now) ==
               "Dentist starts in 10 minutes, at 1086 Cromwell Ln."

      assert Heads.prompt("Dentist", "  ", @start, now) == "Dentist starts in 10 minutes."

      assert Heads.prompt("Sync", "https://zoom.us/j/123456", @start, now) ==
               "Sync starts in 10 minutes."

      assert Heads.prompt("Sync", "meet.google.com/abc-defg-hij", @start, now) ==
               "Sync starts in 10 minutes."
    end

    test "an untitled event still reads naturally" do
      now = ~U[2026-10-10 19:00:00Z]

      assert Heads.prompt("(no title)", nil, @start, now) ==
               "Your next event starts in 10 minutes."

      assert Heads.prompt(nil, nil, @start, now) == "Your next event starts in 10 minutes."
    end
  end
end
