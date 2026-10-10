defmodule AppWeb.DashboardPanelsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias AppWeb.DashboardPanels

  @live %{
    session: :live,
    phase: :awaiting_reflex,
    locked: false,
    bound_device: "abcdef0123456789"
  }
  @none %{session: :none, phase: nil, locked: nil, bound_device: nil}

  test "status strip: a live session shows phase, lock, short device id and who's connected" do
    html =
      render_component(&DashboardPanels.status_strip/1,
        status: @live,
        present: [%{name: "David", kiosk: false}]
      )

    assert html =~ "live"
    assert html =~ "awaiting reflex"
    assert html =~ "unlocked"
    assert html =~ "abcdef01"
    refute html =~ "abcdef0123456789<"
    assert html =~ "David (app)"
  end

  test "status strip: no session shows only that" do
    html = render_component(&DashboardPanels.status_strip/1, status: @none, present: [])
    assert html =~ "no session"
    refute html =~ ~s(id="status-phase")
    refute html =~ ~s(id="status-lock")
    assert html =~ "no one connected"
  end

  test "thread rows render by kind" do
    you = render_component(&DashboardPanels.thread_row/1, row: %{id: "a", kind: :you, text: "hi"})
    assert you =~ ~s(data-kind="you") and you =~ "hi"

    brain =
      render_component(&DashboardPanels.thread_row/1,
        row: %{id: "b", kind: :brain, text: "hello"},
        assistant_name: "Henry"
      )

    assert brain =~ ~s(data-kind="brain") and brain =~ "Henry" and brain =~ "hello"

    tool =
      render_component(&DashboardPanels.thread_row/1,
        row: %{id: "c", kind: :tool, text: "get_weather"}
      )

    assert tool =~ ~s(data-kind="tool") and tool =~ "get_weather"

    reminder =
      render_component(&DashboardPanels.thread_row/1,
        row: %{id: "d", kind: :reminder, text: "Heads up"}
      )

    assert reminder =~ ~s(data-kind="reminder") and reminder =~ "Heads up"
  end

  test "timer, message and heads-up leads get their own colours, like a reminder's" do
    for {kind, colour} <- [timer: "text-timer", message: "text-message", heads_up: "text-drain"] do
      html =
        render_component(&DashboardPanels.thread_row/1, row: %{id: "x", kind: kind, text: "lead"})

      assert html =~ ~s(data-kind="#{kind}")
      assert html =~ colour
      refute html =~ "italic", "an agenda lead is not the dim italic reflex aside"
    end
  end

  test "a Voice Lock gate drop renders its own dim, compact row (finding #2b)" do
    gate =
      render_component(&DashboardPanels.thread_row/1,
        row: %{id: "e", kind: :gate, text: "filtered by Voice Lock"}
      )

    assert gate =~ ~s(data-kind="gate")
    assert gate =~ "filtered by Voice Lock"
    # Same style family as the tool/metrics asides (a compact inline badge), not the generic
    # you/brain/aside bubble, which always renders a separate label line in this exact class.
    refute gate =~ ~s(class="text-[11px] font-semibold leading-4 tracking-wide)
  end

  test "settings: the heads-up row covers calendar events AND rain, one switch for both" do
    user = %{
      name: "Alice",
      email: "a@x.com",
      default_abi: true,
      default_ptt: false,
      voice_activation: true,
      briefing_time: nil,
      heads_up: true,
      relock_seconds: 15
    }

    html = render_component(&DashboardPanels.settings_panel/1, user: user, app_version: "0.0.0")

    assert html =~ "Heads-ups (calendar + rain)"
    refute html =~ "Calendar heads-ups"
  end

  test "short_id tolerates a non-string device id (finding #5)" do
    html =
      render_component(&DashboardPanels.status_strip/1,
        status: %{session: :live, phase: :listening, locked: false, bound_device: 123_456_789},
        present: []
      )

    assert html =~ "12345678"
  end
end
