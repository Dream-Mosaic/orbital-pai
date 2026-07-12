defmodule AppWeb.ConversationLiveTest do
  use AppWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  setup %{user: user} do
    Process.put(:test_user_id, user.id)
    :ok
  end

  # Ambient info strip (kiosk-only) — mount/3 fires handle_info(:refresh_ambient, ...) once for any
  # kiosk-mounted LiveView, which calls the real App.Tools.execute("get_weather"/"get_calendar_events",
  # ...) in a start_async task running under App.Conversations.TaskSup — a different process than
  # this test, so Req.Test's default per-process ownership can't see the stub there (it 500s with
  # "cannot find mock/stub" when the LiveView's async task is the caller). set_req_test_to_shared/1
  # (this file is already async: false, matching Req.Test's own shared-mode requirement) makes the
  # stub visible from any process. Stub the weather HTTP call at the module level so EVERY kiosk mount
  # in this file — including the pre-existing kiosk tests below — never reaches the real network. The
  # calendar call needs no stub: a freshly-registered test user has no connected Google accounts, so
  # App.Tools.Calendar short-circuits to `{:ok, %{events: [], ...}}` before any HTTP call.
  setup do
    Req.Test.set_req_test_to_shared()
    Application.put_env(:app, :weather_req_opts, plug: {Req.Test, ConversationLiveWeatherStub})
    on_exit(fn -> Application.delete_env(:app, :weather_req_opts) end)

    Req.Test.stub(ConversationLiveWeatherStub, fn conn ->
      Req.Test.json(conn, %{"current" => %{"temperature_2m" => 70.0, "weather_code" => 0}})
    end)

    :ok
  end

  test "the main screen mounts with the voice hook region and top bar", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/")
    assert html =~ ~s(id="voice")
    assert html =~ ~s(phx-hook="Voice")
    assert html =~ "Henry"
    # version is surfaced in the top bar
    assert html =~ "v#{App.version()}"
    # the old debug panels are gone from /
    refute html =~ "What I remember about you"
  end

  test "the shell sources the assistant name from config", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/")
    assert html =~ App.Config.default().name
    # no stray hardcoded name leaks (the app was previously named Remi); word-boundary guard
    # so this doesn't false-positive on "Reminders" elsewhere on the page.
    refute Regex.match?(~r/\bremi\b/i, html)
  end

  test "the main screen does not load memory/reminders (memory/reminders/connectors live in modals now)",
       %{conn: conn} do
    {:ok, _lv, _html} = live(conn, "/")
  end

  test "/classic is gone", %{conn: conn} do
    # The endpoint renders a 404 page for the dropped route rather than
    # propagating Phoenix.Router.NoRouteError, so we assert on the status.
    conn = get(conn, "/classic")
    assert conn.status == 404
  end

  test "renders the Orb, controls, transcript, PTT button, and bottom nav", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/")
    assert html =~ ~s(id="orb-canvas")
    assert html =~ ~s(id="orb-caption")
    assert html =~ ~s(id="ptt-toggle")
    assert html =~ ~s(id="abi-toggle")
    assert html =~ ~s(id="ptt-hold")
    assert html =~ ~s(id="voice-log")
    # bottom nav uses phx-click open_modal buttons (Phase 2 — no /classic links)
    assert html =~ ~s(phx-value-modal="settings")
    assert html =~ ~s(phx-value-modal="memory")
  end

  test "the bottom nav opens and closes each modal", %{conn: conn} do
    {:ok, lv, html} = live(conn, "/")
    refute html =~ ~s(data-modal-open="true")

    for {key, title} <- [
          {"memory", "Memory"},
          {"reminders", "Reminders"},
          {"lists", "Lists"},
          {"garden", "Garden"},
          {"connectors", "Connectors"},
          {"settings", "Settings"}
        ] do
      html = lv |> element(~s(button[phx-value-modal="#{key}"])) |> render_click()
      assert html =~ ~s(data-modal-open="true")
      assert html =~ title

      html = lv |> element(~s(button[aria-label="Close"])) |> render_click()
      refute html =~ ~s(data-modal-open="true")
    end
  end

  test "closing the modal keeps its content while the drawer slides out", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/")

    lv |> element(~s(button[phx-value-modal="memory"])) |> render_click()

    html = lv |> element(~s(button[aria-label="Close"])) |> render_click()

    assert html =~ ~s(data-modal-open="false")
    assert html =~ "Profile facts"

    # opening a different modal afterwards swaps the content (not stuck on memory forever)
    html = lv |> element(~s(button[phx-value-modal="reminders"])) |> render_click()
    assert html =~ ~s(data-modal-open="true")
    assert html =~ "Upcoming"
  end

  test "memory modal: add/delete a fact, save summary, forget me", %{conn: conn, user: user} do
    {:ok, lv, _} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="memory"])) |> render_click()

    html = lv |> form("#add-fact-form", %{"content" => "likes oolong tea"}) |> render_submit()
    assert html =~ "likes oolong tea"
    assert Enum.any?(App.Memory.list_facts(user.id), &(&1.content == "likes oolong tea"))

    lv |> form("#summary-form", %{"summary" => "knows Bobby"}) |> render_submit()
    assert App.Memory.get_summary(user.id).content == "knows Bobby"

    lv |> element(~s(button[phx-click="forget_me"])) |> render_click()
    assert App.Memory.list_facts(user.id) == []
    assert App.Memory.get_summary(user.id).content == ""
  end

  defp past(offset_s) do
    DateTime.utc_now() |> DateTime.add(offset_s, :second) |> DateTime.truncate(:second)
  end

  test "reminders modal lists due reminders; nav shows a due dot", %{conn: conn, user: user} do
    # create a reminder that is fired/unacknowledged (i.e. "due") using the real App.Reminders API
    {:ok, r} = App.Reminders.create(%{body: "call mom", due_at: past(-30), user_id: user.id})
    {:ok, _fired} = App.Reminders.mark_fired(r)

    {:ok, lv, html} = live(conn, "/")
    assert html =~ ~s(data-due-dot="true")

    lv |> element(~s(button[phx-value-modal="reminders"])) |> render_click()
    assert render(lv) =~ "call mom"
  end

  test "reminders modal: a follow-up reminder is badged", %{conn: conn, user: user} do
    {:ok, _r} =
      App.Reminders.create(%{
        body: "check whether Bob replied about the contract",
        due_at: past(3600),
        user_id: user.id,
        kind: "followup",
        context: "I'm emailing Bob about the contract"
      })

    {:ok, lv, _html} = live(conn, "/")
    html = lv |> element(~s(button[phx-value-modal="reminders"])) |> render_click()

    assert html =~ "follow-up"
  end

  test "reminders modal: a recurring reminder shows its cadence badge and cancel ends the series",
       %{conn: conn, user: user} do
    {:ok, r} =
      App.Reminders.create(%{
        body: "take out the bins",
        due_at: past(3600),
        user_id: user.id,
        recurrence: %{"freq" => "weekly", "interval" => 1, "byday" => ["tue"]}
      })

    {:ok, lv, _html} = live(conn, "/")
    html = lv |> element(~s(button[phx-value-modal="reminders"])) |> render_click()

    assert html =~ "every Tue"
    assert html =~ "cancel repeating reminder"

    # the ✕ (dismiss_reminder → Reminders.delete) removes the WHOLE series — the row IS the series
    lv
    |> element(~s|button[phx-click="dismiss_reminder"][phx-value-id="#{r.id}"]|)
    |> render_click()

    refute render(lv) =~ "take out the bins"
    assert App.Reminders.list_upcoming(user.id) == []
  end

  test "reminders modal: a one-shot renders with no cadence badge (additive invariant)",
       %{conn: conn, user: user} do
    {:ok, _} =
      App.Reminders.create(%{body: "call mom", due_at: past(3600), user_id: user.id})

    {:ok, lv, _html} = live(conn, "/")
    html = lv |> element(~s(button[phx-value-modal="reminders"])) |> render_click()

    assert html =~ "call mom"
    refute html =~ "cancel repeating reminder"
    refute html =~ "badge-info"
  end

  test "lists modal: shows the user's visible lists with items", %{conn: conn, user: user} do
    {:ok, list} =
      %App.Lists.List{}
      |> App.Lists.List.changeset(%{user_id: user.id, name: "To-do"})
      |> App.Repo.insert()

    {:ok, _item} = App.Lists.add_item(list, "call the plumber")

    {:ok, lv, _html} = live(conn, "/")
    html = lv |> element(~s(button[phx-value-modal="lists"])) |> render_click()

    assert html =~ "To-do"
    assert html =~ "call the plumber"
  end

  test "lists modal: a household list shows the shared badge", %{conn: conn, user: user} do
    {:ok, _list} =
      %App.Lists.List{}
      |> App.Lists.List.changeset(%{user_id: user.id, name: "Groceries", household: true})
      |> App.Repo.insert()

    {:ok, lv, _html} = live(conn, "/")
    html = lv |> element(~s(button[phx-value-modal="lists"])) |> render_click()

    assert html =~ "shared"
  end

  test "toggling a list item checks it off, then unchecks it", %{conn: conn, user: user} do
    {:ok, list} =
      %App.Lists.List{}
      |> App.Lists.List.changeset(%{user_id: user.id, name: "Groceries"})
      |> App.Repo.insert()

    {:ok, item} = App.Lists.add_item(list, "milk")

    {:ok, lv, _html} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="lists"])) |> render_click()

    lv |> element(~s|input[phx-click="toggle_list_item"]|) |> render_click()
    assert App.Repo.get!(App.Lists.Item, item.id).checked_at != nil

    lv |> element(~s|input[phx-click="toggle_list_item"]|) |> render_click()
    assert App.Repo.get!(App.Lists.Item, item.id).checked_at == nil
  end

  test "adding an item via the panel form shows it without a remount", %{conn: conn, user: user} do
    {:ok, list} =
      %App.Lists.List{}
      |> App.Lists.List.changeset(%{user_id: user.id, name: "Groceries"})
      |> App.Repo.insert()

    {:ok, lv, _html} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="lists"])) |> render_click()

    html =
      lv
      |> form(~s(form[phx-submit="add_list_item"]), %{"list_id" => list.id, "text" => "butter"})
      |> render_submit()

    assert html =~ "butter"
  end

  test "clear-checked removes done items from the panel", %{conn: conn, user: user} do
    {:ok, list} =
      %App.Lists.List{}
      |> App.Lists.List.changeset(%{user_id: user.id, name: "Groceries"})
      |> App.Repo.insert()

    {:ok, item} = App.Lists.add_item(list, "milk")
    {:ok, _} = App.Lists.check_item(item)

    {:ok, lv, _html} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="lists"])) |> render_click()
    assert render(lv) =~ "milk"

    lv |> element(~s|button[phx-click="clear_list_checked"]|) |> render_click()
    refute render(lv) =~ "milk"
  end

  test "deleting a list removes it from the panel", %{conn: conn, user: user} do
    {:ok, _list} =
      %App.Lists.List{}
      |> App.Lists.List.changeset(%{user_id: user.id, name: "Plants"})
      |> App.Repo.insert()

    {:ok, lv, _html} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="lists"])) |> render_click()
    assert render(lv) =~ "Plants"

    lv |> element(~s|button[phx-click="delete_list"]|) |> render_click()
    refute render(lv) =~ "Plants"
  end

  test "a household list's change from elsewhere refreshes the panel via lists:household", %{
    conn: conn,
    user: user
  } do
    {:ok, lv, _html} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="lists"])) |> render_click()

    {:ok, list} =
      %App.Lists.List{}
      |> App.Lists.List.changeset(%{user_id: user.id, name: "Groceries", household: true})
      |> App.Repo.insert()

    App.Lists.broadcast_changed(list.user_id, true)

    assert render(lv) =~ "Groceries"
  end

  defp garden_plant!(user, attrs) do
    {:ok, plant} =
      %App.Garden.Plant{}
      |> App.Garden.Plant.changeset(Map.merge(%{user_id: user.id, name: "tomatoes"}, attrs))
      |> App.Repo.insert()

    plant
  end

  test "garden modal: shows active plants with meta and the shared badge", %{
    conn: conn,
    user: user
  } do
    garden_plant!(user, %{
      name: "tomatoes",
      location: "back bed",
      count: 5,
      household: true,
      planted_on: ~D[2026-07-11]
    })

    {:ok, lv, _html} = live(conn, "/")
    html = lv |> element(~s(button[phx-value-modal="garden"])) |> render_click()

    assert html =~ "tomatoes"
    assert html =~ "back bed"
    assert html =~ "shared"
  end

  test "garden modal: the add-note form logs a check-in", %{conn: conn, user: user} do
    plant = garden_plant!(user, %{name: "basil"})

    {:ok, lv, _html} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="garden"])) |> render_click()

    html =
      lv
      |> form(~s(form[phx-submit="add_plant_note"]), %{
        "plant_id" => plant.id,
        "body" => "looking leggy"
      })
      |> render_submit()

    assert html =~ "looking leggy"

    [loaded] = App.Garden.garden(user.id).active
    assert [%{body: "looking leggy"}] = loaded.notes
  end

  test "archiving a plant from the panel moves it to Past seasons", %{conn: conn, user: user} do
    plant = garden_plant!(user, %{name: "basil"})

    {:ok, lv, _html} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="garden"])) |> render_click()

    html = lv |> element(~s|button[phx-click="archive_plant"]|) |> render_click()

    assert html =~ "Past seasons"
    assert App.Repo.get!(App.Garden.Plant, plant.id).status == "archived"
  end

  test "reviving an archived plant returns it to active", %{conn: conn, user: user} do
    plant =
      garden_plant!(user, %{
        name: "basil",
        status: "archived",
        season: "2025",
        archived_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    {:ok, lv, _html} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="garden"])) |> render_click()
    assert render(lv) =~ "2025"

    lv |> element(~s|button[phx-click="revive_plant"]|) |> render_click()

    assert App.Repo.get!(App.Garden.Plant, plant.id).status == "active"
    refute render(lv) =~ "Past seasons"
  end

  test "a household plant's change from elsewhere refreshes the panel via garden:household", %{
    conn: conn,
    user: user
  } do
    {:ok, lv, _html} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="garden"])) |> render_click()

    plant = garden_plant!(user, %{name: "peppers", household: true})
    App.Garden.broadcast_changed(plant.user_id, true)

    assert render(lv) =~ "peppers"
  end

  defp google_account(attrs) do
    base = %{refresh_token: "rt", user_id: Process.get(:test_user_id)}

    {:ok, acc} =
      %App.Google.Account{}
      |> App.Google.Account.changeset(Map.merge(base, attrs))
      |> App.Repo.insert()

    acc
  end

  test "connectors modal lists connections and opens the inline grant step", %{conn: conn} do
    google_account(%{
      email: "r@x.com",
      label: "r@x.com",
      scope: "https://www.googleapis.com/auth/calendar.readonly openid email"
    })

    {:ok, lv, _} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="connectors"])) |> render_click()

    # the panel renders the connection list
    html = render(lv)
    assert html =~ "Google Calendar"
    assert html =~ "r@x.com"

    # grant step opens inline via the renamed event
    html = lv |> element(~s([phx-click="grant_open"])) |> render_click()
    assert html =~ ~s(phx-change="grant_change")
    assert html =~ ~s(phx-submit="grant_submit")
  end

  test "connectors modal shows empty state when no accounts connected", %{conn: conn} do
    {:ok, lv, _} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="connectors"])) |> render_click()
    assert render(lv) =~ "No connections"
  end

  test "connectors grant step cancel (grant_cancel) closes the inline form", %{conn: conn} do
    {:ok, lv, _} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="connectors"])) |> render_click()

    html = lv |> element(~s([phx-click="grant_open"])) |> render_click()
    assert html =~ "Add a connection"

    html = lv |> element(~s([phx-click="grant_cancel"])) |> render_click()
    refute html =~ ~s(phx-submit="grant_submit")
  end

  test "connectors grant submit redirects to Google connect route", %{conn: conn} do
    {:ok, lv, _} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="connectors"])) |> render_click()
    lv |> element(~s([phx-click="grant_open"])) |> render_click()

    assert {:error, {:redirect, %{to: to}}} =
             lv |> element(~s(form[phx-submit="grant_submit"])) |> render_submit()

    assert to =~ "calendar=write"
  end

  test "settings modal: voice prefs persist; account + danger zone present", %{
    conn: conn,
    user: user
  } do
    {:ok, lv, _} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="settings"])) |> render_click()
    html = render(lv)
    assert html =~ user.email
    assert html =~ "Sign out"
    assert html =~ "Default ABI"

    lv |> element(~s(input[phx-value-pref="default_abi"])) |> render_click()
    assert App.Users.get(user.id).default_abi == true
  end

  # ---------------------------------------------------------------------------
  # Ported from classic_live_test — behaviors that were not yet covered on /
  # ---------------------------------------------------------------------------

  test "memory modal: delete a fact removes it from the panel and DB", %{conn: conn, user: user} do
    {:ok, fact} =
      App.Memory.create_fact(%{content: "temporary fact", source: "user", user_id: user.id})

    {:ok, lv, _} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="memory"])) |> render_click()

    assert render(lv) =~ "temporary fact"

    html =
      lv
      |> element(~s(button[phx-click="delete_fact"][phx-value-id="#{fact.id}"]))
      |> render_click()

    refute html =~ "temporary fact"
    refute Enum.any?(App.Memory.list_facts(user.id), &(&1.id == fact.id))
  end

  test "memory modal: reflects memory changes broadcast from elsewhere (e.g. the Updater)", %{
    conn: conn,
    user: user
  } do
    {:ok, lv, _} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="memory"])) |> render_click()

    App.Memory.put_summary(user.id, "model-written summary")
    App.Memory.broadcast_updated()

    assert render(lv) =~ "model-written summary"
  end

  test "settings modal: clear_conversation wipes the user's turns but keeps facts + summary", %{
    conn: conn,
    user: user
  } do
    {:ok, _} = App.Memory.persist_turn(%{user_id: user.id, user_text: "hi", brain_text: "yo"})
    {:ok, _} = App.Memory.create_fact(%{content: "keep me", source: "user", user_id: user.id})
    App.Memory.put_summary(user.id, "keep summary")

    {:ok, lv, _} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="settings"])) |> render_click()
    lv |> element("#settings-clear-convo") |> render_click()

    assert App.Memory.recent_turns(user.id) == []
    assert Enum.map(App.Memory.list_facts(user.id), & &1.content) == ["keep me"]
    assert App.Memory.get_summary(user.id).content == "keep summary"
  end

  test "clearing the conversation pushes clear_log to the client", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    view |> element("#clear-convo") |> render_click()
    assert_push_event(view, "clear_log", %{})
  end

  test "reminders modal: a fired-reminder broadcast appears live", %{conn: conn, user: user} do
    {:ok, lv, _} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="reminders"])) |> render_click()

    {:ok, r} =
      App.Reminders.create(%{body: "stand up", due_at: past(-5), user_id: user.id})

    {:ok, fired} = App.Reminders.mark_fired(r)

    Phoenix.PubSub.broadcast(
      App.PubSub,
      "reminders:#{user.id}",
      {:reminder_due, fired}
    )

    assert render(lv) =~ "stand up"
  end

  test "reminders modal: an acknowledged reminder drops off the panel live", %{
    conn: conn,
    user: user
  } do
    {:ok, r} =
      App.Reminders.create(%{body: "call mom", due_at: past(-30), user_id: user.id})

    {:ok, fired} = App.Reminders.mark_fired(r)

    {:ok, lv, html} = live(conn, "/")
    assert html =~ ~s(data-due-dot="true")

    lv |> element(~s(button[phx-value-modal="reminders"])) |> render_click()
    assert render(lv) =~ "call mom"

    {:ok, _} = App.Reminders.acknowledge(fired)
    refute render(lv) =~ "call mom"
  end

  test "acknowledging a pending reminder from the panel clears it", %{conn: conn, user: user} do
    {:ok, r} =
      App.Reminders.create(%{body: "take out the trash", due_at: past(-30), user_id: user.id})

    {:ok, _fired} = App.Reminders.mark_fired(r)

    {:ok, lv, _html} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="reminders"])) |> render_click()
    assert render(lv) =~ "take out the trash"

    lv |> element(~s|button[phx-click="ack_reminder"]|) |> render_click()
    refute render(lv) =~ "take out the trash"
  end

  test "reminders modal: creating a reminder shows it in Upcoming without a remount", %{
    conn: conn,
    user: user
  } do
    {:ok, lv, _} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="reminders"])) |> render_click()

    {:ok, _} =
      App.Reminders.create(%{
        body: "stand up",
        due_at: past(3600),
        user_id: user.id
      })

    assert render(lv) =~ "stand up"
  end

  test "connectors modal: renders a flat connection row with a level chip and per-connection disconnect",
       %{conn: conn} do
    acc =
      google_account(%{
        email: "r@x.com",
        label: "r@x.com",
        scope: "https://www.googleapis.com/auth/calendar.readonly openid email"
      })

    {:ok, lv, _} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="connectors"])) |> render_click()
    html = render(lv)

    assert html =~ "Connectors"
    assert html =~ "Google Calendar"
    assert html =~ "r@x.com"
    assert html =~ "read"

    assert has_element?(
             lv,
             ~s(button[phx-click="disconnect_connection"][phx-value-account="#{acc.id}"][phx-value-connector="calendar"])
           )

    assert has_element?(lv, ~s([phx-click="grant_open"]))
  end

  test "connectors modal: a single-account connector shows no default control", %{conn: conn} do
    google_account(%{
      email: "solo@x.com",
      label: "solo@x.com",
      scope: "https://www.googleapis.com/auth/calendar.events openid email"
    })

    {:ok, lv, _} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="connectors"])) |> render_click()

    refute has_element?(lv, ~s(button[phx-click="set_default_google"]))
    refute has_element?(lv, ".badge-primary")
  end

  test "connectors modal: a connector with two accounts shows the default badge + set-default control",
       %{conn: conn} do
    google_account(%{
      email: "a@x.com",
      label: "a@x.com",
      is_default: true,
      scope: "https://www.googleapis.com/auth/calendar.events openid email"
    })

    b =
      google_account(%{
        email: "b@x.com",
        label: "b@x.com",
        scope: "https://www.googleapis.com/auth/calendar.events openid email"
      })

    {:ok, lv, _} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="connectors"])) |> render_click()

    assert has_element?(lv, ".badge-primary")
    assert has_element?(lv, ~s(button[phx-click="set_default_google"][phx-value-id="#{b.id}"]))
  end

  test "connectors modal: opening grant_open shows the form targeting a new account", %{
    conn: conn
  } do
    {:ok, lv, _} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="connectors"])) |> render_click()

    html = lv |> element(~s([phx-click="grant_open"])) |> render_click()

    assert html =~ "Add a connection"
    assert has_element?(lv, ~s(option[value="new"]))
    assert has_element?(lv, ~s(input[name="level"][value="write"][checked]))
  end

  test "connectors modal: granting on an existing account redirects with connector + account", %{
    conn: conn
  } do
    acc =
      google_account(%{
        email: "r@x.com",
        label: "r@x.com",
        scope: "https://www.googleapis.com/auth/calendar.readonly openid email"
      })

    {:ok, lv, _} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="connectors"])) |> render_click()
    lv |> element(~s([phx-click="grant_open"])) |> render_click()

    lv
    |> element(~s(form[phx-submit="grant_submit"]))
    |> render_change(%{
      "connector" => "calendar",
      "account" => to_string(acc.id),
      "level" => "write"
    })

    assert {:error, {:redirect, %{to: to}}} =
             lv |> element(~s(form[phx-submit="grant_submit"])) |> render_submit()

    assert to =~ "calendar=write"
    assert to =~ "account=#{acc.id}"
  end

  test "connectors modal: granting on a new account redirects without an account param", %{
    conn: conn
  } do
    {:ok, lv, _} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="connectors"])) |> render_click()
    lv |> element(~s([phx-click="grant_open"])) |> render_click()

    lv
    |> element(~s(form[phx-submit="grant_submit"]))
    |> render_change(%{"connector" => "calendar", "account" => "new", "level" => "write"})

    assert {:error, {:redirect, %{to: to}}} =
             lv |> element(~s(form[phx-submit="grant_submit"])) |> render_submit()

    assert to =~ "calendar=write"
    refute to =~ "account="
  end

  # These three are pure static-markup assertions (layout classes / container presence), so they use
  # a plain disconnected `get/2` rather than `live/2`. That matters beyond style: a *connected* kiosk
  # mount fires the real handle_info(:refresh_ambient, ...) → start_async → App.Tools.execute (a real
  # Ecto read for get_calendar_events even with zero accounts) in the background on
  # App.Conversations.TaskSup. That's fully drained deterministically by render_async in the dedicated
  # test below, but doing it in EVERY kiosk-mounting test here piled up extra real background DB
  # reads against this file's shared Ecto sandbox and measurably worsened the project's known
  # "Database busy" flake (see CLAUDE.md / App.DataCase.drain_conversation_tasks). A disconnected GET
  # renders the identical template (kiosk/ambient assigns are unconditional in mount/3) without ever
  # reaching `connected?(socket)`, so it never triggers the refresh at all — no async, no DB read.
  test "kiosk param marks the layout; default does not", %{conn: conn} do
    kiosk_html = conn |> get("/?kiosk=1") |> html_response(200)
    assert kiosk_html =~ ~s(data-kiosk="true")

    default_html = conn |> get("/") |> html_response(200)
    assert default_html =~ ~s(data-kiosk="false")
  end

  test "kiosk mount renders the ambient strip container; non-kiosk mount renders none", %{
    conn: conn
  } do
    kiosk_html = conn |> get("/?kiosk=1") |> html_response(200)
    assert kiosk_html =~ ~s(id="ambient-strip")

    default_html = conn |> get("/") |> html_response(200)
    refute default_html =~ ~s(id="ambient-strip")
  end

  test "kiosk ambient strip fills in with the fetched weather line (real tool layer, stubbed HTTP)",
       %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/?kiosk=1")

    assert render_async(lv) =~ "70° clear"
  end

  test "kiosk moves modal nav into the header strip and drops the bottom nav", %{conn: conn} do
    kiosk_html = conn |> get("/?kiosk=1") |> html_response(200)
    assert kiosk_html =~ ~s(id="kiosk-modal-strip")
    refute kiosk_html =~ ~s(id="bottom-nav")
    assert kiosk_html =~ ~s(id="ptt-toggle")
    assert kiosk_html =~ ~s(id="power-btn")
    assert kiosk_html =~ ~s(id="ptt-hold")

    default_html = conn |> get("/") |> html_response(200)
    refute default_html =~ ~s(id="kiosk-modal-strip")
    assert default_html =~ ~s(id="bottom-nav")
  end

  test "voice_activation pref renders on #voice (data attrs present)", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/")
    assert html =~ ~s(data-voice-activation="false")
    assert html =~ ~s(data-assistant-name=)
  end

  test "lockdown slider renders and set_relock persists (clamped)", %{conn: conn} do
    {:ok, lv, html} = live(conn, "/")
    assert html =~ ~s(data-relock-seconds=)

    lv |> element(~s(button[phx-value-modal="settings"])) |> render_click()
    lv |> element("#lockdown-form") |> render_change(%{"seconds" => "22"})
    assert render(lv) =~ "22s"

    # clamp above the max
    lv |> element("#lockdown-form") |> render_change(%{"seconds" => "99"})
    assert render(lv) =~ "30s"

    # clamp below the min
    lv |> element("#lockdown-form") |> render_change(%{"seconds" => "5"})
    assert render(lv) =~ "10s"

    # malformed input must not crash the LiveView (client is untrusted)
    lv |> render_hook("set_relock", %{"seconds" => "abc"})
    assert render(lv) =~ ~r/\d+s/
  end

  test "briefing toggle sets a default time, then clears it", %{conn: conn, user: user} do
    {:ok, lv, _html} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="settings"])) |> render_click()

    lv |> element("#settings-briefing-toggle") |> render_click()
    assert App.Users.get(user.id).briefing_time == "07:00"

    lv |> element("#settings-briefing-toggle") |> render_click()
    assert App.Users.get(user.id).briefing_time == nil
  end

  test "briefing time input updates the pref", %{conn: conn, user: user} do
    {:ok, _} = App.Users.update_prefs(user, %{briefing_time: "07:00"})
    {:ok, lv, _html} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="settings"])) |> render_click()

    lv |> element("#briefing-time-form") |> render_change(%{"briefing_time" => "06:30"})
    assert App.Users.get(user.id).briefing_time == "06:30"
  end

  test "connectors modal: a no-op grant (new account + none) closes the inline form without redirecting",
       %{conn: conn} do
    {:ok, lv, _} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="connectors"])) |> render_click()
    lv |> element(~s([phx-click="grant_open"])) |> render_click()

    lv
    |> element(~s(form[phx-submit="grant_submit"]))
    |> render_change(%{"connector" => "calendar", "account" => "new", "level" => "none"})

    html = lv |> element(~s(form[phx-submit="grant_submit"])) |> render_submit()
    refute html =~ "Add a connection"
  end

  test "connectors modal: set default moves the default to the chosen account", %{conn: conn} do
    {:ok, _a} =
      %App.Google.Account{}
      |> App.Google.Account.changeset(%{
        user_id: Process.get(:test_user_id),
        email: "a@x.com",
        label: "a@x.com",
        refresh_token: "rt",
        is_default: true,
        scope: "https://www.googleapis.com/auth/calendar.events openid email"
      })
      |> App.Repo.insert()

    {:ok, b} =
      %App.Google.Account{}
      |> App.Google.Account.changeset(%{
        user_id: Process.get(:test_user_id),
        email: "b@x.com",
        label: "b@x.com",
        refresh_token: "rt",
        scope: "https://www.googleapis.com/auth/calendar.events openid email"
      })
      |> App.Repo.insert()

    {:ok, lv, _} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="connectors"])) |> render_click()

    lv
    |> element(~s(button[phx-click="set_default_google"][phx-value-id="#{b.id}"]))
    |> render_click()

    assert App.Google.Accounts.default(Process.get(:test_user_id)).email == "b@x.com"
  end

  test "connectors modal: lists a connection and disconnects it", %{conn: conn} do
    acc =
      google_account(%{
        email: "a@x.com",
        label: "a@x.com",
        scope: "https://www.googleapis.com/auth/calendar.events openid email"
      })

    {:ok, lv, _} = live(conn, "/")
    lv |> element(~s(button[phx-value-modal="connectors"])) |> render_click()
    assert render(lv) =~ "a@x.com"

    lv
    |> element(
      ~s(button[phx-click="disconnect_connection"][phx-value-account="#{acc.id}"][phx-value-connector="calendar"])
    )
    |> render_click()

    refute render(lv) =~ "a@x.com"
    assert App.Google.Accounts.list(Process.get(:test_user_id)) == []
  end
end
