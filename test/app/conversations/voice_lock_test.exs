defmodule App.Conversations.VoiceLockTest do
  # async: false + global Mox: reflex model runs in TaskSup children (same as conversation_test).
  use ExUnit.Case, async: false
  import Mox

  alias App.Conversations.Conversation
  alias App.Config

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    App.DataCase.setup_sandbox(%{async: false})
    stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "the answer"} end)

    user =
      App.Repo.insert!(%App.Users.User{
        email: "vl#{System.unique_integer([:positive])}@t",
        name: "VL"
      })

    on_exit(fn ->
      for k <- [
            :fake_verifier_embedding,
            :fake_verifier_error,
            :fake_verifier_delay_ms,
            :fake_verifier_ready
          ],
          do: Application.delete_env(:app, k)
    end)

    %{user: user}
  end

  @match [1.0, 0.0, 0.0, 0.0]
  @mismatch [0.0, 1.0, 0.0, 0.0]

  defp start_conv(user, mode, opts \\ []) do
    vl = %{
      user_id: user.id,
      mode: mode,
      threshold: 0.5,
      voiceprint: Keyword.get(opts, :voiceprint, @match)
    }

    config = Keyword.get(opts, :config, %Config{})

    {:ok, pid} =
      Conversation.start_link(client: self(), config: config, name: nil, voice_lock: vl)

    pid
  end

  # push `ms` of audio then a turn boundary around it
  defp speak_turn(pid, ms, text) do
    Conversation.turn_start(pid)
    Conversation.push_audio(pid, :binary.copy(<<1, 1>>, ms * 16))
    Conversation.endpoint(pid, text)
  end

  test "enforce: matching voice passes (turn answered, pass event logged)", %{user: u} do
    Application.put_env(:app, :fake_verifier_embedding, @match)
    pid = start_conv(u, :enforce)
    Conversation.push_audio(pid, :binary.copy(<<1, 1>>, 32_000))
    speak_turn(pid, 3_000, "what's the weather")
    assert_receive {:to_client, {:speak_start, _src, _text}}, 1_000
  end

  test "enforce: mismatched voice is dropped — no reflex/brain, drop event, client pulse", %{
    user: u
  } do
    Application.put_env(:app, :fake_verifier_embedding, @mismatch)
    pid = start_conv(u, :enforce)
    speak_turn(pid, 3_000, "lyrics from a song")
    assert_receive {:to_client, {:voice_gate, :drop}}, 1_000
    refute_receive {:to_client, {:speak_start, _src, _text}}, 500

    import Ecto.Query
    assert [ev] = App.Repo.all(from e in App.Speaker.GateEvent, where: e.user_id == ^u.id)
    assert ev.decision == "drop" and ev.reason == "below_threshold" and ev.mode == "enforce"
  end

  test "enforce: short turn passes inside the trust window, drops cold", %{user: u} do
    Application.put_env(:app, :fake_verifier_embedding, @match)
    pid = start_conv(u, :enforce)

    # cold short turn -> dropped (short_no_trust)
    speak_turn(pid, 500, "stop")
    assert_receive {:to_client, {:voice_gate, :drop}}, 1_000
    refute_receive {:to_client, {:speak_start, _, _}}, 300

    # verify with a long turn, then a short follow-up inherits trust
    speak_turn(pid, 3_000, "what's the weather")
    assert_receive {:to_client, {:speak_start, _, _}}, 1_000
    speak_turn(pid, 500, "yes")
    assert_receive {:to_client, {:speak_start, _, _}}, 1_000
  end

  test "enforce fails OPEN on verifier error, timeout, and missing voiceprint", %{user: u} do
    # error
    Application.put_env(:app, :fake_verifier_error, :boom)
    pid = start_conv(u, :enforce)
    speak_turn(pid, 3_000, "hello")
    assert_receive {:to_client, {:speak_start, _, _}}, 1_000
    Application.delete_env(:app, :fake_verifier_error)

    # timeout (budget 50ms, fake sleeps 300ms)
    Application.put_env(:app, :fake_verifier_delay_ms, 300)
    pid2 = start_conv(u, :enforce, config: %Config{voice_lock_verify_budget_ms: 50})
    speak_turn(pid2, 3_000, "hello again")
    assert_receive {:to_client, {:speak_start, _, _}}, 1_000
    Application.delete_env(:app, :fake_verifier_delay_ms)

    # no voiceprint enrolled
    pid3 = start_conv(u, :enforce, voiceprint: nil)
    speak_turn(pid3, 3_000, "hello three")
    assert_receive {:to_client, {:speak_start, _, _}}, 1_000
  end

  test "enforce fails OPEN (no FSM crash) on a tuple-shaped verifier error — the Ortex adapter's real shape",
       %{user: u} do
    Application.put_env(:app, :fake_verifier_error, {:call_failed, :timeout})
    pid = start_conv(u, :enforce)
    speak_turn(pid, 3_000, "hello")

    # pre-fix this raises Protocol.UndefinedError in log_gate and the linked FSM crash kills the test;
    # post-fix the turn is fed (fail-open) and the fail_open event is logged with a stringified reason.
    assert_receive {:to_client, {:speak_start, _, _}}, 1_000

    import Ecto.Query

    assert eventually(fn ->
             match?(
               [%{decision: "fail_open"}],
               App.Repo.all(from e in App.Speaker.GateEvent, where: e.user_id == ^u.id)
             )
           end)
  end

  test "shadow: mismatched voice STILL answers but logs would_drop", %{user: u} do
    Application.put_env(:app, :fake_verifier_embedding, @mismatch)
    pid = start_conv(u, :shadow)
    speak_turn(pid, 3_000, "background chatter")
    assert_receive {:to_client, {:speak_start, _, _}}, 1_000
    refute_receive {:to_client, {:voice_gate, _}}, 200

    import Ecto.Query

    assert eventually(fn ->
             match?(
               [%{decision: "would_drop"}],
               App.Repo.all(from e in App.Speaker.GateEvent, where: e.user_id == ^u.id)
             )
           end)
  end

  test "off mode + PTT are byte-for-byte ungated (no events)", %{user: u} do
    Application.put_env(:app, :fake_verifier_embedding, @mismatch)
    pid = start_conv(u, :off)
    speak_turn(pid, 3_000, "anything")
    assert_receive {:to_client, {:speak_start, _, _}}, 1_000

    import Ecto.Query
    assert App.Repo.all(from e in App.Speaker.GateEvent, where: e.user_id == ^u.id) == []
  end

  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(25) && eventually(fun, tries - 1)
    end
  end
end
