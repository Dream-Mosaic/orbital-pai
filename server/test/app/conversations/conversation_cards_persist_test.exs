defmodule App.Conversations.ConversationCardsPersistTest do
  # The cards a turn SHOWED ride along into its persisted row, so a history replay can put them
  # back in the thread. Collected at emit time — a card held behind the reflex counts once it is
  # released, one dropped with an aborted turn never does.
  #
  # async: false + global Mox (the reflex runs in Task.Supervisor children) and the shared
  # sandbox, same as conversation_test.exs: turns persist from a TaskSup child.
  use ExUnit.Case, async: false
  import Mox

  alias App.Conversations.Conversation
  alias App.Config

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    App.DataCase.setup_sandbox(%{async: false})
    stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "huh"} end)
    on_exit(fn -> Application.put_env(:app, :fake_brain_done_ms, 0) end)
    :ok
  end

  @groceries %{
    list: "Groceries",
    household: true,
    items: [%{text: "milk", checked: false}, %{text: "eggs", checked: true}]
  }

  # A real, allowlisted user (persistence is keyed by the user id parsed back out of the
  # session string), with the wake gate pinned off so endpoint/2 isn't swallowed while locked.
  defp test_user do
    Application.put_env(:app, :allowed_users, [%{email: "cards@x.com", name: "Cards Test"}])
    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, user} = App.Users.upsert_allowed("cards@x.com")
    {:ok, user} = App.Users.update_prefs(user, %{voice_activation: false})
    user
  end

  defp start_session(user, config \\ %Config{}) do
    {:ok, pid} =
      Conversation.start_link(
        client: self(),
        config: config,
        name: nil,
        session_id: to_string(user.id)
      )

    pid
  end

  # Synchronous stop before the sandbox owner goes (see conversation_test.exs: an in-flight
  # init pull outliving its owner is how the next test sees "Database busy").
  defp stop_session(pid), do: :gen_statem.stop(pid, :normal, 2_000)

  defp eventually(fun, tries \\ 60) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if tries <= 0, do: flunk("condition not met within ~1.2s")
        Process.sleep(20)
        eventually(fun, tries - 1)

      value ->
        value
    end
  end

  defp persisted(user, user_text) do
    eventually(fn ->
      Enum.find(App.Memory.recent_turns(user.id, 5), &(&1.user_text == user_text))
    end)
  end

  test "a card the user saw is persisted with its turn, as the client saw it" do
    Application.put_env(:app, :fake_brain_done_ms, 300)
    user = test_user()
    pid = start_session(user)

    Conversation.endpoint(pid, "what's on the grocery list")
    # the reflex AUDIO is the gate: once it is out, a card goes straight to the client
    assert_receive {:to_client, {:audio, :reflex, _}}, 1000
    send(pid, {:brain_tool_result, "read_list", %{"list" => "groceries"}, @groceries})
    assert_receive {:to_client, {:card, %{type: "list"} = shown}}, 500

    turn = persisted(user, "what's on the grocery list")
    assert turn.brain_text == "the answer"
    # string keys on the way back out of the JSON column, i.e. exactly the wire shape
    assert [card] = turn.cards
    assert card == shown |> Jason.encode!() |> Jason.decode!()
    stop_session(pid)
  end

  test "a card held behind the reflex is persisted once it is released" do
    Application.put_env(:app, :fake_brain_done_ms, 600)

    stub(App.TextModelMock, :generate, fn _t, _c, _o ->
      Process.sleep(250)
      {:ok, "huh"}
    end)

    user = test_user()
    pid = start_session(user)

    Conversation.endpoint(pid, "what's on the grocery list")
    # lands before the reflex has spoken -> held in card_buffer, released by :flush_brain
    send(pid, {:brain_tool_result, "read_list", %{}, @groceries})
    assert_receive {:to_client, {:card, %{type: "list"}}}, 1500

    assert [%{"type" => "list", "title" => "Groceries"}] =
             persisted(user, "what's on the grocery list").cards

    stop_session(pid)
  end

  test "a turn that showed no cards persists none" do
    user = test_user()
    pid = start_session(user)

    Conversation.endpoint(pid, "hello")
    assert persisted(user, "hello").cards == nil
    stop_session(pid)
  end

  test "a turn keeps at most four cards" do
    Application.put_env(:app, :fake_brain_done_ms, 300)
    user = test_user()
    pid = start_session(user)

    Conversation.endpoint(pid, "show me my lists")
    assert_receive {:to_client, {:audio, :reflex, _}}, 1000

    for n <- 1..5 do
      send(pid, {:brain_tool_result, "read_list", %{}, %{@groceries | list: "List #{n}"}})
    end

    for _ <- 1..5, do: assert_receive({:to_client, {:card, _}}, 500)

    titles = persisted(user, "show me my lists").cards |> Enum.map(& &1["title"])
    assert titles == ["List 1", "List 2", "List 3", "List 4"]
    stop_session(pid)
  end

  test "the next turn starts with no cards of its own" do
    Application.put_env(:app, :fake_brain_done_ms, 300)
    user = test_user()
    pid = start_session(user)

    Conversation.endpoint(pid, "what's on the grocery list")
    assert_receive {:to_client, {:audio, :reflex, _}}, 1000
    send(pid, {:brain_tool_result, "read_list", %{}, @groceries})
    assert_receive {:to_client, {:card, _}}, 500
    assert [_] = persisted(user, "what's on the grocery list").cards

    Conversation.endpoint(pid, "thanks")
    assert persisted(user, "thanks").cards == nil
    stop_session(pid)
  end

  # Interrupted turns, documented behaviour:
  #   * answered, then barged (the row persists, its answer truncated to what was heard): the
  #     cards were on screen, so the row KEEPS them.
  #   * barged before any answer (the request carries forward into the next turn): the aborted
  #     turn's cards are DROPPED with it. The next turn's brain answers both requests and its
  #     tools re-run, so the row it persists carries the cards that turn shows, not a duplicate
  #     set from the abandoned attempt.
  test "an answered turn the user barged into keeps the cards it showed" do
    Application.put_env(:app, :fake_brain_done_ms, 300)
    user = test_user()
    # a wide jitter buffer holds the turn in :draining long enough to barge after the answer
    pid = start_session(user, %Config{jitter_buffer_ms: 2_000})

    Conversation.endpoint(pid, "what's on the grocery list")
    assert_receive {:to_client, {:audio, :reflex, _}}, 1000
    send(pid, {:brain_tool_result, "read_list", %{}, @groceries})
    assert_receive {:to_client, {:card, _}}, 500
    assert_receive {:to_client, {:speak_start, :brain, "the answer"}}, 1000

    Conversation.barge_in(pid)
    assert_receive {:to_client, :stop_playback}, 1000

    assert [%{"type" => "list"}] = persisted(user, "what's on the grocery list").cards
    stop_session(pid)
  end

  test "a turn barged before its answer drops its cards; the carried turn keeps only its own" do
    Application.put_env(:app, :fake_brain_done_ms, 5_000)
    user = test_user()
    pid = start_session(user)

    Conversation.endpoint(pid, "what's on the grocery list")
    assert_receive {:to_client, {:audio, :reflex, _}}, 1000
    send(pid, {:brain_tool_result, "read_list", %{}, @groceries})
    assert_receive {:to_client, {:card, _}}, 500

    Conversation.barge_in(pid)
    assert_receive {:to_client, :stop_playback}, 1000

    Application.put_env(:app, :fake_brain_done_ms, 0)
    Conversation.endpoint(pid, "and the hardware list")

    # the carried-forward request is folded into this turn's transcript
    turn = persisted(user, "what's on the grocery list and the hardware list")
    assert turn.cards == nil
    stop_session(pid)
  end

  test "an agenda turn that persists (persist_as) keeps its cards" do
    Application.put_env(:app, :fake_brain_done_ms, 300)
    user = test_user()
    pid = start_session(user)

    item = %App.Agenda.Item{
      kind: :briefing,
      prompt: "give the briefing",
      persist_as: "(morning briefing)"
    }

    send(pid, {:agenda_due, item})
    assert_receive {:to_client, {:audio, :briefing, _}}, 1000
    send(pid, {:brain_tool_result, "read_list", %{}, @groceries})
    assert_receive {:to_client, {:card, _}}, 500

    assert [%{"type" => "list"}] = persisted(user, "(morning briefing)").cards
    stop_session(pid)
  end
end
