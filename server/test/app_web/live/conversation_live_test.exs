defmodule AppWeb.ConversationLiveTest do
  use AppWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias App.Conversations.Sessions

  setup :register_and_log_in_user

  defp mirror(user, event),
    do: Phoenix.PubSub.broadcast(App.PubSub, "conversation:#{user.id}", {:mirror, event})

  # A running Conversation reads the DB from its own process; stop it synchronously before
  # the test (the sandbox owner) exits, or its in-flight reads outlive the connection (#23).
  defp start_session!(user) do
    sid = to_string(user.id)
    {:ok, pid} = Sessions.start(sid, self())
    {sid, pid}
  end

  defp past(offset_s),
    do: DateTime.utc_now() |> DateTime.add(offset_s, :second) |> DateTime.truncate(:second)

  describe "the page" do
    test "is the dashboard: header, status, thread, inspector; no voice client", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/")
      assert html =~ "v#{App.version()}"
      assert html =~ App.Config.default().name
      assert html =~ ~s(id="status")
      assert html =~ ~s(id="thread")
      assert html =~ ~s(id="inspector")
      refute html =~ "phx-hook"
      refute html =~ "data-user-token"
    end

    test "has no write controls, only UI-local events", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/")

      for tab <- ~w(reminders books memory connectors voice_lock settings) do
        html = lv |> element(~s(#inspector [phx-value-tab="#{tab}"])) |> render_click()
        refute html =~ "phx-submit"
        refute html =~ "phx-change"

        # JS commands (the flash group's own close, `[[&quot;push&quot;,…`) are client-side
        # and not writes; every named server event must be UI-local.
        clicks =
          Regex.scan(~r/phx-click="([^"]+)"/, html)
          |> Enum.map(&List.last/1)
          |> Enum.reject(&String.starts_with?(&1, "["))

        assert Enum.all?(clicks, &(&1 in ["tab", "show_book"])), inspect(clicks)
      end
    end

    test "PWA install meta is gone", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/")
      refute html =~ "manifest.webmanifest"
      refute html =~ "apple-mobile-web-app-capable"
    end
  end

  describe "the live mirror" do
    test "history renders on mount, oldest first", %{conn: conn, user: user} do
      {:ok, _} =
        App.Memory.persist_turn(%{user_id: user.id, user_text: "first q", brain_text: "first a"})

      {:ok, _} =
        App.Memory.persist_turn(%{
          user_id: user.id,
          user_text: "second q",
          brain_text: "second a"
        })

      {:ok, _lv, html} = live(conn, "/")
      assert html =~ "first a"
      {first, _} = :binary.match(html, "first q")
      {second, _} = :binary.match(html, "second q")
      assert first < second
    end

    test "mirrored events render live: caption, transcript, a growing answer, tools, metrics",
         %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, "/")

      mirror(user, {:partial, "what's the"})
      assert render(lv) =~ "what&#39;s the"
      assert has_element?(lv, "#caption")

      mirror(user, {:transcript, "what's the weather"})
      mirror(user, {:tool_call, "get_weather"})
      mirror(user, {:brain_delta, "Sunny "})
      mirror(user, {:brain_delta, "and warm."})
      mirror(user, {:metrics, 640, 3_410})

      html = render(lv)
      refute has_element?(lv, "#caption")
      assert html =~ "what&#39;s the weather"
      assert html =~ "get_weather"
      assert html =~ "Sunny and warm."
      assert html =~ "audio 0.6s · brain 3.4s"
    end

    test "a long unbreakable token in a brain row carries the wrap-anywhere class, not a scrollbar",
         %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, "/")

      long_url = "https://example.com/" <> String.duplicate("a", 120)
      mirror(user, {:brain_delta, long_url})

      html = render(lv)
      assert html =~ long_url

      assert has_element?(
               lv,
               ~s(div[data-kind="brain"] .chat-bubble[class*="overflow-wrap:anywhere"])
             )
    end

    test "no session, then a session starts and the strip goes live", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, "/")
      assert lv |> element("#status-session") |> render() =~ "no session"

      {sid, pid} = start_session!(user)
      # Conversation.init broadcasts :session_started; the LiveView looks it up and snapshots.
      assert render(lv) =~ "listening"
      assert lv |> element("#status-session") |> render() =~ "live"

      :ok = Sessions.stop(sid)
      refute Process.alive?(pid)
      assert lv |> element("#status-session") |> render() =~ "no session"
    end

    test "mounting mid-session reads the snapshot", %{conn: conn, user: user} do
      {sid, _pid} = start_session!(user)
      {:ok, lv, _html} = live(conn, "/")
      assert lv |> element("#status-session") |> render() =~ "live"
      assert lv |> element("#status-phase") |> render() =~ "listening"
      :ok = Sessions.stop(sid)
    end

    test "a session ending clears the strip and the caption", %{conn: conn, user: user} do
      {sid, _pid} = start_session!(user)
      {:ok, lv, _html} = live(conn, "/")
      mirror(user, {:partial, "half a sent"})
      assert has_element?(lv, "#caption")

      :ok = Sessions.stop(sid)
      assert lv |> element("#status-session") |> render() =~ "no session"
      refute has_element?(lv, "#caption")

      # A straggler after the end must not crash the page.
      mirror(user, {:brain_delta, "late"})
      assert render(lv) =~ "late"
    end

    test "a stale :DOWN from a previous session is ignored", %{conn: conn, user: user} do
      {sid, old} = start_session!(user)
      {:ok, lv, _html} = live(conn, "/")

      # Simulate a message race: a :DOWN for some other pid than the one being watched.
      send(lv.pid, {:DOWN, make_ref(), :process, spawn(fn -> :ok end), :normal})
      assert lv |> element("#status-session") |> render() =~ "live"
      assert Process.alive?(old)
      :ok = Sessions.stop(sid)
    end

    test "two dashboards both mirror; neither registers with the conversation",
         %{conn: conn, user: user} do
      {sid, pid} = start_session!(user)
      {:ok, a, _} = live(conn, "/")
      {:ok, b, _} = live(conn, "/")

      mirror(user, {:transcript, "seen twice"})
      assert render(a) =~ "seen twice"
      assert render(b) =~ "seen twice"

      {_state, data} = :sys.get_state(pid)
      assert data.device_ids == %{}
      assert data.client == self()
      :ok = Sessions.stop(sid)
    end
  end

  describe "the inspector" do
    test "reminders: due and upcoming, refreshed by broadcast", %{conn: conn, user: user} do
      {:ok, r} = App.Reminders.create(%{body: "call mom", due_at: past(-30), user_id: user.id})
      {:ok, _} = App.Reminders.mark_fired(r)

      {:ok, lv, html} = live(conn, "/")
      assert html =~ "call mom"

      {:ok, _} =
        App.Reminders.create(%{body: "water plants", due_at: past(3_600), user_id: user.id})

      assert render(lv) =~ "water plants"
    end

    test "books: a list's items, and switching books is local", %{conn: conn, user: user} do
      {:ok, list} =
        %App.Lists.List{}
        |> App.Lists.List.changeset(%{user_id: user.id, name: "To-do"})
        |> App.Repo.insert()

      {:ok, _} = App.Lists.add_item(list, "call the plumber")

      {:ok, lv, _} = live(conn, "/")
      html = lv |> element(~s(#inspector [phx-value-tab="books"])) |> render_click()
      assert html =~ "call the plumber"

      html = lv |> element(~s(#panel-books [phx-value-key="garden"])) |> render_click()
      assert html =~ "Nothing growing."
      # Local: the stored preference is untouched.
      assert App.Users.get(user.id).books_last_book == user.books_last_book
    end

    test "memory: reflects a broadcast from elsewhere", %{conn: conn, user: user} do
      {:ok, lv, _} = live(conn, "/")
      lv |> element(~s(#inspector [phx-value-tab="memory"])) |> render_click()

      App.Memory.put_summary(user.id, "model-written summary")
      App.Memory.broadcast_updated()
      assert render(lv) =~ "model-written summary"
    end

    test "connectors: a connection row with its access level", %{conn: conn, user: user} do
      {:ok, _} =
        %App.Google.Account{}
        |> App.Google.Account.changeset(%{
          refresh_token: "rt",
          user_id: user.id,
          email: "r@x.com",
          label: "r@x.com",
          scope: "https://www.googleapis.com/auth/calendar.readonly openid email"
        })
        |> App.Repo.insert()

      {:ok, lv, _} = live(conn, "/")
      html = lv |> element(~s(#inspector [phx-value-tab="connectors"])) |> render_click()
      assert html =~ "Google Calendar"
      assert html =~ "r@x.com"
      # Scoped to the access-level badge itself — `html =~ "read"` alone can never fail, since
      # `render_click` returns the WHOLE view and `id="thread"` always contains "read".
      assert has_element?(lv, "#panel-connectors .badge", "read")
    end

    test "settings: shows the stored prefs, read fresh on tab open", %{conn: conn, user: user} do
      {:ok, lv, _} = live(conn, "/")
      {:ok, _} = App.Users.update_prefs(user, %{briefing_time: "06:45"})

      html = lv |> element(~s(#inspector [phx-value-tab="settings"])) |> render_click()
      assert html =~ "06:45"
      assert html =~ user.email
    end

    test "voice lock: mode and enrollment count", %{conn: conn} do
      {:ok, lv, _} = live(conn, "/")
      html = lv |> element(~s(#inspector [phx-value-tab="voice_lock"])) |> render_click()
      assert html =~ "Enrolled prompts"
      assert html =~ "of 3"
    end
  end
end
