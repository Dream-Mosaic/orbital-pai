defmodule App.Conversations.ConversationTest do
  # async: false + global Mox because the reflex model runs in Task.Supervisor children.
  use ExUnit.Case, async: false
  import Mox

  alias App.Conversations.Conversation
  alias App.Config

  setup :set_mox_global
  setup :verify_on_exit!

  # The Conversation persists turns in a TaskSup child (not the test process); a shared-mode
  # sandbox lets that background task use the test's DB connection instead of logging an
  # OwnershipError. async: false, so shared mode is safe.
  setup do
    App.DataCase.setup_sandbox(%{async: false})
    :ok
  end

  # Brain audio is faked (App.Test.Fakes.BrainStream); only the reflex hits the model mock.
  @config %Config{}

  defp start_conv(config \\ @config) do
    {:ok, pid} = Conversation.start_link(client: self(), config: config, name: nil)
    pid
  end

  describe "voice activation gate" do
    test "locked: an utterance WITHOUT the name produces no response" do
      stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "the answer"} end)
      pid = start_conv()
      Conversation.set_voice_activation(pid, true)
      assert_receive {:to_client, {:locked, true}}, 500
      Conversation.endpoint(pid, "what's the weather like")
      refute_receive {:to_client, {:speak_start, _src, _text}}, 500
    end

    test "name unlocks and the same utterance is answered; follow-ups stay unlocked" do
      stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "the answer"} end)
      pid = start_conv()
      Conversation.set_voice_activation(pid, true)
      assert_receive {:to_client, {:locked, true}}, 500

      Conversation.endpoint(pid, "Henry, what's the weather")
      assert_receive {:to_client, {:locked, false}}, 500
      assert_receive {:to_client, {:speak_start, _src, _text}}, 1000

      Conversation.endpoint(pid, "and tomorrow")
      assert_receive {:to_client, {:speak_start, _src, _text}}, 1000
    end

    test "re-locks after the idle window; then a no-name utterance is silent again" do
      Application.put_env(:app, :relock_ms, 60)
      on_exit(fn -> Application.delete_env(:app, :relock_ms) end)
      stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "the answer"} end)
      pid = start_conv()
      Conversation.set_voice_activation(pid, true)
      # drain the initial lock so the next {:locked, true} is unambiguously the re-lock
      assert_receive {:to_client, {:locked, true}}, 500

      Conversation.endpoint(pid, "Henry hello")
      assert_receive {:to_client, {:locked, false}}, 1000
      # drain BOTH the reflex and the brain speak_start of this (unlocked) turn so the later
      # refute can't catch a straggler from "Henry hello"
      assert_receive {:to_client, {:speak_start, :reflex, _}}, 1000
      assert_receive {:to_client, {:speak_start, :brain, _}}, 1000
      # the re-lock fires after the idle window
      assert_receive {:to_client, {:locked, true}}, 1000

      Conversation.endpoint(pid, "are you there")
      refute_receive {:to_client, {:speak_start, _src, _text}}, 400
    end

    test "a live partial resets the idle relock (no mid-utterance lock)" do
      Application.put_env(:app, :relock_ms, 200)
      on_exit(fn -> Application.delete_env(:app, :relock_ms) end)
      stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "the answer"} end)
      pid = start_conv()
      Conversation.set_voice_activation(pid, true)
      assert_receive {:to_client, {:locked, true}}, 500

      # wake + answer -> unlocked. The idle relock only ARMS when the turn fully completes and
      # phase returns to :listening (the :drained transition, signaled by {:to_client, :listening})
      # -- not at the earlier unlock moment -- so drain the whole turn before timing anything.
      Conversation.endpoint(pid, "Henry hello")
      assert_receive {:to_client, {:locked, false}}, 500
      assert_receive {:to_client, {:speak_start, :reflex, _}}, 1000
      assert_receive {:to_client, {:speak_start, :brain, _}}, 1000
      assert_receive {:to_client, :listening}, 1000

      # ~120ms later (before the 200ms window elapses) a live partial arrives -> must RESET it
      Process.sleep(120)
      Conversation.partial(pid, "i am still talking")

      # 120ms after the partial (~240ms since the relock armed, but only ~120ms since the
      # partial): WITHOUT the fix the un-reset 200ms timer already fired -> this refute FAILS (RED)
      refute_receive {:to_client, {:locked, true}}, 120

      # then real silence past a fresh window -> it finally locks
      assert_receive {:to_client, {:locked, true}}, 400
    end

    test "with voice activation OFF (default), a no-name utterance is answered (no regression)" do
      stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "the answer"} end)
      pid = start_conv()
      Conversation.endpoint(pid, "what's the weather")
      assert_receive {:to_client, {:speak_start, _src, _text}}, 1000
    end

    test "set_relock_ms overrides the idle relock window" do
      stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "the answer"} end)
      pid = start_conv()
      Conversation.set_voice_activation(pid, true)
      assert_receive {:to_client, {:locked, true}}, 500
      Conversation.set_relock_ms(pid, 60)

      # wake + answer -> unlocked; the turn completes and arms the 60ms override -> relocks fast
      Conversation.endpoint(pid, "Henry hello")
      assert_receive {:to_client, {:locked, false}}, 500
      assert_receive {:to_client, {:locked, true}}, 1000
    end
  end

  describe "voice activation v2: endpoint gate" do
    test "TV-blob prefix is stripped: the brain sees only the command" do
      Process.register(self(), :fake_brain_observer)
      stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "hm"} end)
      pid = start_conv()
      Conversation.set_voice_activation(pid, true)
      assert_receive {:to_client, {:locked, true}}, 500

      Conversation.endpoint(pid, "and the game ended. wake up Henry, what's the weather?")
      assert_receive {:to_client, {:locked, false}}, 500
      assert_receive {:to_client, {:transcript, "what's the weather?"}}, 1000
      assert_receive {:fake_brain_transcript, "what's the weather?"}, 1000
    end

    test "a locked utterance without a trigger is dropped AND logged" do
      # The drop line logs at :info, but the test env's primary Logger level is :warning
      # (config/test.exs), which filters :info before ANY handler (incl. CaptureLog) sees it.
      # Bump the primary level for this one test so the :info line is capturable (async: false
      # makes this global mutation safe); restore it on exit.
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)

      pid = start_conv()
      Conversation.set_voice_activation(pid, true)
      assert_receive {:to_client, {:locked, true}}, 500

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Conversation.endpoint(pid, "totally unrelated tv chatter")
          refute_receive {:to_client, {:speak_start, _, _}}, 300
        end)

      assert log =~ ~s|[wake] locked drop: "totally unrelated tv chatter"|
    end

    test "bare wake -> instant spoken ack, no reflex model, no brain turn" do
      Process.register(self(), :fake_brain_observer)
      pid = start_conv()
      Conversation.set_voice_activation(pid, true)
      assert_receive {:to_client, {:locked, true}}, 500

      Conversation.endpoint(pid, "wake up Henry")
      assert_receive {:to_client, {:locked, false}}, 500
      assert_receive {:to_client, {:speak_start, :reflex, ack}}, 500
      assert ack in ["Yeah?", "Hm?", "Mm?", "Go on."]
      assert_receive {:to_client, {:audio, :reflex, _}}, 500
      refute_receive {:fake_brain_transcript, _}, 300
    end

    test "the ack's own echo cannot start a self-turn" do
      Process.register(self(), :fake_brain_observer)
      pid = start_conv()
      Conversation.set_voice_activation(pid, true)
      assert_receive {:to_client, {:locked, true}}, 500

      Conversation.endpoint(pid, "Henry")
      assert_receive {:to_client, {:speak_start, :reflex, ack}}, 500

      Conversation.endpoint(pid, ack)
      refute_receive {:fake_brain_transcript, _}, 300
    end

    test "'Henry stop, what's the time' answers the tail" do
      Process.register(self(), :fake_brain_observer)
      stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "hm"} end)
      pid = start_conv()
      Conversation.set_voice_activation(pid, true)
      assert_receive {:to_client, {:locked, true}}, 500

      Conversation.endpoint(pid, "Henry stop, what's the time")
      assert_receive {:fake_brain_transcript, "what's the time"}, 1000
    end

    test "fuzzy: 'Henri, what's up' unlocks (distance 1)" do
      stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "hm"} end)
      pid = start_conv()
      Conversation.set_voice_activation(pid, true)
      assert_receive {:to_client, {:locked, true}}, 500

      Conversation.endpoint(pid, "Henri, what's up")
      assert_receive {:to_client, {:locked, false}}, 500
      assert_receive {:to_client, {:speak_start, _, _}}, 1000
    end

    test "an armed re-lock that fires mid-turn defers instead of locking" do
      Application.put_env(:app, :relock_ms, 100)
      Application.put_env(:app, :fake_brain_done_ms, 300)

      on_exit(fn ->
        Application.delete_env(:app, :relock_ms)
        Application.delete_env(:app, :fake_brain_done_ms)
      end)

      stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "hm"} end)
      pid = start_conv()
      Conversation.set_voice_activation(pid, true)
      assert_receive {:to_client, {:locked, true}}, 500

      # bare wake arms the 100ms re-lock…
      Conversation.endpoint(pid, "Henry")
      assert_receive {:to_client, {:speak_start, :reflex, _ack}}, 500
      # …then a turn starts before it fires (brain takes 300ms)
      Conversation.endpoint(pid, "what's the time")
      # the timer fires mid-turn -> deferred, no lock during the turn
      refute_receive {:to_client, {:locked, true}}, 250
      assert_receive {:to_client, {:speak_start, :brain, _}}, 2000
      # after completion the deferred re-lock lands
      assert_receive {:to_client, {:locked, true}}, 2000
    end
  end

  describe "voice activation v2: partials + safety stop" do
    test "a locked partial with the trigger unlocks and captions the stripped remainder" do
      pid = start_conv()
      Conversation.set_voice_activation(pid, true)
      assert_receive {:to_client, {:locked, true}}, 500

      Conversation.partial(pid, "blah blah. hey Henry what's")
      assert_receive {:to_client, {:locked, false}}, 500
      assert_receive {:to_client, {:partial, "what's"}}, 500

      # cumulative partials keep stripping for the rest of the window
      Conversation.partial(pid, "blah blah. hey Henry what's the weather")
      assert_receive {:to_client, {:partial, "what's the weather"}}, 500
    end

    test "a locked partial without a trigger stays silent (no caption)" do
      pid = start_conv()
      Conversation.set_voice_activation(pid, true)
      assert_receive {:to_client, {:locked, true}}, 500

      Conversation.partial(pid, "just the tv talking")
      refute_receive {:to_client, {:partial, _}}, 300
    end

    test "safety stop: 'Henry stop' during playback halts even when locked with ABI off" do
      Application.put_env(:app, :fake_brain_done_ms, 500)
      on_exit(fn -> Application.delete_env(:app, :fake_brain_done_ms) end)
      stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "hm"} end)
      pid = start_conv()

      Conversation.endpoint(pid, "tell me a story")
      assert_receive {:to_client, {:speak_start, :reflex, _}}, 1000

      # lock lands mid-turn (kiosk pref toggled / rejoin) — the worst case
      Conversation.set_voice_activation(pid, true)
      assert_receive {:to_client, {:locked, true}}, 500

      Conversation.partial(pid, "Henry stop")
      assert_receive {:to_client, :stop_playback}, 500
      assert_receive {:to_client, {:locked, false}}, 500
    end

    test "locked + ABI on: a wordy partial without the trigger does NOT interrupt" do
      Application.put_env(:app, :fake_brain_done_ms, 500)
      on_exit(fn -> Application.delete_env(:app, :fake_brain_done_ms) end)
      stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "hm"} end)
      pid = start_conv()
      Conversation.set_allow_interruptions(pid, true)

      Conversation.endpoint(pid, "tell me a story")
      assert_receive {:to_client, {:speak_start, :reflex, _}}, 1000

      Conversation.set_voice_activation(pid, true)
      assert_receive {:to_client, {:locked, true}}, 500

      Conversation.turn_start(pid)
      Conversation.partial(pid, "some perfectly wordy tv dialogue")
      refute_receive {:to_client, :stop_playback}, 300
    end

    test "ABI still confirms when voice activation is on but unlocked" do
      Application.put_env(:app, :fake_brain_done_ms, 500)
      on_exit(fn -> Application.delete_env(:app, :fake_brain_done_ms) end)
      stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "hm"} end)
      pid = start_conv()
      Conversation.set_allow_interruptions(pid, true)
      Conversation.set_voice_activation(pid, true)
      assert_receive {:to_client, {:locked, true}}, 500

      Conversation.endpoint(pid, "Henry tell me a story")
      assert_receive {:to_client, {:locked, false}}, 500
      assert_receive {:to_client, {:speak_start, :reflex, _}}, 1000

      Conversation.turn_start(pid)
      Conversation.partial(pid, "actually never mind that")
      assert_receive {:to_client, :stop_playback}, 500
    end

    test "eager_end pre-computes the reflex on the STRIPPED text" do
      test_pid = self()

      stub(App.TextModelMock, :generate, fn t, _c, opts ->
        if Keyword.get(opts, :tier) == :reflex, do: send(test_pid, {:reflex_input, t})
        {:ok, "hm"}
      end)

      pid = start_conv()
      Conversation.set_voice_activation(pid, true)
      assert_receive {:to_client, {:locked, true}}, 500

      Conversation.partial(pid, "junk junk. hey Henry what's the")
      assert_receive {:to_client, {:locked, false}}, 500

      Conversation.eager_end(pid, "junk junk. hey Henry what's the weather")
      assert_receive {:reflex_input, "what's the weather"}, 1000
    end

    test "safety stop discards the interrupted request (no carry-forward into the next turn)" do
      Process.register(self(), :fake_brain_observer)
      Application.put_env(:app, :fake_brain_done_ms, 500)
      on_exit(fn -> Application.delete_env(:app, :fake_brain_done_ms) end)
      stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "hm"} end)
      pid = start_conv()

      # a turn is mid-think: reflex has spoken, the brain is still working (no brain_text yet)
      Conversation.endpoint(pid, "tell me a story")
      assert_receive {:fake_brain_transcript, "tell me a story"}, 1000
      assert_receive {:to_client, {:speak_start, :reflex, _}}, 1000

      # safety stop while it's thinking (brain not done -> would carry-forward without the fix)
      Conversation.set_voice_activation(pid, true)
      assert_receive {:to_client, {:locked, true}}, 500
      Conversation.partial(pid, "Henry stop")
      assert_receive {:to_client, :stop_playback}, 500
      assert_receive {:to_client, {:locked, false}}, 500

      # a brand-new question: the brain must see ONLY it, not "tell me a story what's the time"
      Conversation.endpoint(pid, "Henry what's the time")
      assert_receive {:fake_brain_transcript, "what's the time"}, 1000
    end
  end

  describe "voice activation: sleep command" do
    test "sleep partial during playback halts AND re-locks" do
      Application.put_env(:app, :fake_brain_done_ms, 500)
      on_exit(fn -> Application.delete_env(:app, :fake_brain_done_ms) end)
      stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "hm"} end)
      pid = start_conv()
      Conversation.set_voice_activation(pid, true)
      assert_receive {:to_client, {:locked, true}}, 500

      Conversation.endpoint(pid, "Henry tell me a story")
      assert_receive {:to_client, {:locked, false}}, 500
      assert_receive {:to_client, {:speak_start, :reflex, _}}, 1000

      Conversation.partial(pid, "Henry sleep")
      assert_receive {:to_client, :stop_playback}, 500
      assert_receive {:to_client, {:locked, true}}, 500
    end

    test "sleep at the endpoint while awake re-locks and runs no turn" do
      Process.register(self(), :fake_brain_observer)
      stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "hm"} end)
      pid = start_conv()
      Conversation.set_voice_activation(pid, true)
      assert_receive {:to_client, {:locked, true}}, 500

      Conversation.endpoint(pid, "Henry hello")
      assert_receive {:to_client, {:locked, false}}, 500
      assert_receive {:fake_brain_transcript, "hello"}, 1000

      Conversation.endpoint(pid, "Henry go to sleep")
      assert_receive {:to_client, {:locked, true}}, 500
      refute_receive {:fake_brain_transcript, _}, 300
    end

    test "sleep at the endpoint while already locked stays locked (no unlock, no turn)" do
      Process.register(self(), :fake_brain_observer)
      stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "hm"} end)
      pid = start_conv()
      Conversation.set_voice_activation(pid, true)
      assert_receive {:to_client, {:locked, true}}, 500

      Conversation.endpoint(pid, "Henry sleep")
      refute_receive {:to_client, {:locked, false}}, 300
      refute_receive {:fake_brain_transcript, _}, 300
    end

    test "'Henry stop' halts but stays awake (unlocks, does not re-lock)" do
      Application.put_env(:app, :fake_brain_done_ms, 500)
      on_exit(fn -> Application.delete_env(:app, :fake_brain_done_ms) end)
      stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "hm"} end)
      pid = start_conv()

      Conversation.endpoint(pid, "tell me a story")
      assert_receive {:to_client, {:speak_start, :reflex, _}}, 1000

      Conversation.set_voice_activation(pid, true)
      assert_receive {:to_client, {:locked, true}}, 500

      Conversation.partial(pid, "Henry stop")
      assert_receive {:to_client, :stop_playback}, 500
      # stop stays awake -> it UNLOCKS (a sleep would instead keep {:locked, true})
      assert_receive {:to_client, {:locked, false}}, 500
    end

    test "sleep partial while locked + speaking stays locked (barges, no unlock)" do
      Application.put_env(:app, :fake_brain_done_ms, 500)
      on_exit(fn -> Application.delete_env(:app, :fake_brain_done_ms) end)
      stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "hm"} end)
      pid = start_conv()

      # a turn is mid-flight, then the lock lands mid-turn (worst case: locked + speaking)
      Conversation.endpoint(pid, "tell me a story")
      assert_receive {:to_client, {:speak_start, :reflex, _}}, 1000

      Conversation.set_voice_activation(pid, true)
      assert_receive {:to_client, {:locked, true}}, 500

      # "Henry sleep" while locked + speaking → barges, stays locked (no {:locked, false})
      Conversation.partial(pid, "Henry sleep")
      assert_receive {:to_client, :stop_playback}, 500
      refute_receive {:to_client, {:locked, false}}, 300
    end
  end

  test "endpoint -> transcript, reflex audio, streamed brain audio, brain text — in order" do
    expect(App.TextModelMock, :generate, fn _t, _ctx, opts ->
      assert Keyword.fetch!(opts, :tier) == :reflex
      {:ok, "huh, okay"}
    end)

    pid = start_conv()
    Conversation.endpoint(pid, "why X")

    assert_receive {:to_client, {:transcript, "why X"}}, 1000
    assert_receive {:to_client, {:speak_start, :reflex, "huh, okay"}}, 1000
    assert_receive {:to_client, {:audio, :reflex, _}}, 1000
    assert_receive {:to_client, {:audio, :brain, _}}, 1000
    assert_receive {:to_client, {:speak_start, :brain, "the answer"}}, 1000
  end

  test "forwards live partial transcripts to the client while listening" do
    pid = start_conv()
    Conversation.partial(pid, "what's the wea")
    assert_receive {:to_client, {:partial, "what's the wea"}}, 1000
  end

  test "metrics: TTFA on reflex audio, TTB on first brain audio" do
    stub(App.TextModelMock, :generate, fn _t, _c, _opts -> {:ok, "huh"} end)

    pid = start_conv()
    Conversation.endpoint(pid, "q")

    # reflex audio -> ttfa set, ttb still nil
    assert_receive {:to_client, {:metrics, ttfa, nil}}, 1000
    assert is_integer(ttfa) and ttfa >= 0
    # brain audio -> ttb set
    assert_receive {:to_client, {:metrics, _ttfa, ttb}}, 1000
    assert is_integer(ttb) and ttb >= 0
  end

  test "reflex model error falls back to canned text; the brain still streams" do
    stub(App.TextModelMock, :generate, fn _t, _c, _opts -> {:error, :boom} end)

    pid = start_conv()
    Conversation.endpoint(pid, "q")

    assert_receive {:to_client, {:speak_start, :reflex, "Hm, go on?"}}, 1000
    assert_receive {:to_client, {:audio, :brain, _}}, 1000
    assert_receive {:to_client, {:speak_start, :brain, "the answer"}}, 1000
  end

  test "a brain-stream failure falls back to the batch brain (text + audio)" do
    Application.put_env(:app, :fake_brain_error, true)
    on_exit(fn -> Application.delete_env(:app, :fake_brain_error) end)

    stub(App.TextModelMock, :generate, fn _t, _c, opts ->
      case Keyword.fetch!(opts, :tier) do
        :reflex -> {:ok, "huh"}
        :brain -> {:ok, "the fallback answer"}
      end
    end)

    pid = start_conv()
    Conversation.endpoint(pid, "q")

    assert_receive {:to_client, {:speak_start, :reflex, "huh"}}, 1000
    assert_receive {:to_client, {:speak_start, :brain, "the fallback answer"}}, 2000
    assert_receive {:to_client, {:audio, :brain, _}}, 2000
  end

  test "streams brain text deltas to the client mid-turn" do
    Application.put_env(:app, :fake_brain_text_deltas, ["The ", "answer."])
    on_exit(fn -> Application.delete_env(:app, :fake_brain_text_deltas) end)
    stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "huh"} end)

    pid = start_conv()
    Conversation.endpoint(pid, "q")

    assert_receive {:to_client, {:brain_delta, "The "}}, 1000
    assert_receive {:to_client, {:brain_delta, "answer."}}, 1000
    # the final full text still arrives as the markdown-finalize signal
    assert_receive {:to_client, {:speak_start, :brain, "the answer"}}, 1000
  end

  test "an empty brain answer never goes silent — speaks a canned line instead" do
    # The prod bug: the brain ran tools but produced no spoken text, the turn finished with
    # {:brain_done, ""}, and the assistant said nothing. It must speak a graceful canned line.
    Application.put_env(:app, :fake_brain_done_text, "")
    on_exit(fn -> Application.delete_env(:app, :fake_brain_done_text) end)
    stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "huh"} end)

    pid = start_conv()
    Conversation.endpoint(pid, "what's on my calendar")

    assert_receive {:to_client, {:speak_start, :brain, line}}, 2000

    assert is_binary(line) and String.trim(line) != "",
           "brain must not go silent on an empty answer"

    # and the canned line is actually spoken (audio), not just captioned
    assert_receive {:to_client, {:audio, :brain, _}}, 2000
  end

  test "an empty answer that follows a bridge (TTB already set) STILL speaks a canned line" do
    # Reproduces the prod miss: a tool "bridge" plays after the reflex and sets TTB, so a
    # is_nil(ttb) guard would treat the bridge-then-empty turn as "already answered" and let the
    # silence through. Delaying the done lets the brain's early audio flush (after reflex) → TTB set.
    Application.put_env(:app, :fake_brain_done_text, "")
    Application.put_env(:app, :fake_brain_done_ms, 300)

    on_exit(fn ->
      Application.delete_env(:app, :fake_brain_done_text)
      Application.put_env(:app, :fake_brain_done_ms, 0)
    end)

    stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "huh"} end)

    pid = start_conv()
    Conversation.endpoint(pid, "what's on my calendar")

    # the brain's early audio flushes after the reflex completes → TTB becomes a real number
    assert_receive {:to_client, {:metrics, _ttfa, ttb}} when is_integer(ttb), 2000

    # despite TTB being set, the empty final answer must still yield a spoken canned line
    assert_receive {:to_client, {:speak_start, :brain, line}}, 2000
    assert is_binary(line) and String.trim(line) != "", "bridge-then-empty must not go silent"
  end

  test "turn.start takes no action — Phase A diagnostic logs only, never aborts a turn" do
    pid = start_conv()
    Conversation.turn_start(pid)

    # diagnostic only: no barge-in, no client message, and the session stays up (handler wired)
    refute_receive {:to_client, _}, 200
    assert Process.alive?(pid)
  end

  test "a stale brain_text delta (idle / abandoned turn) is dropped" do
    pid = start_conv()
    # no turn in flight -> phase :listening -> the delta must not reach the client
    send(pid, {:brain_text, "stale"})
    refute_receive {:to_client, {:brain_delta, _}}, 200
  end

  test "barge-in stops playback and kills the brain stream" do
    # keep the brain stream open so we can barge in mid-stream
    Application.put_env(:app, :fake_brain_done_ms, 5_000)
    on_exit(fn -> Application.put_env(:app, :fake_brain_done_ms, 0) end)
    stub(App.TextModelMock, :generate, fn _t, _c, _opts -> {:ok, "huh"} end)

    pid = start_conv()
    Conversation.endpoint(pid, "q")
    assert_receive {:to_client, {:audio, :reflex, _}}, 1000
    assert_receive {:to_client, {:audio, :brain, _}}, 1000

    Conversation.barge_in(pid)
    assert_receive {:to_client, :stop_playback}, 1000
    refute_receive {:to_client, {:speak_start, :brain, _}}, 300
    assert Process.alive?(pid)
  end

  test "barging in BEFORE the brain answers carries the unanswered request into the next turn" do
    # keep the brain stream open so the first request is never answered (brain_text stays nil)
    Application.put_env(:app, :fake_brain_done_ms, 5_000)
    on_exit(fn -> Application.put_env(:app, :fake_brain_done_ms, 0) end)
    Process.register(self(), :fake_brain_observer)

    on_exit(fn ->
      if Process.whereis(:fake_brain_observer), do: Process.unregister(:fake_brain_observer)
    end)

    stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "huh"} end)

    pid = start_conv()
    Conversation.endpoint(pid, "check my calendar")
    assert_receive {:fake_brain_transcript, "check my calendar"}, 1000
    assert_receive {:to_client, {:audio, :brain, _}}, 1000

    # interrupt before the calendar answer is delivered
    Conversation.barge_in(pid)
    assert_receive {:to_client, :stop_playback}, 1000

    # the next turn's brain receives the unanswered request folded in with the new utterance
    Conversation.endpoint(pid, "also can I fly drones")
    assert_receive {:fake_brain_transcript, combined}, 1000
    assert combined =~ "check my calendar"
    assert combined =~ "also can I fly drones"
  end

  test "barging in AFTER the brain answered persists the completed turn (not carried)" do
    # a real user session: persistence is keyed by user_id, resolved from the session string.
    Application.put_env(:app, :allowed_users, [%{email: "d@x.com", name: "Alice"}])
    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, user} = App.Users.upsert_allowed("d@x.com")

    # a wide jitter buffer keeps the turn in :draining long enough to barge after brain_done
    stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "huh"} end)

    pid = start_conv_session(%Config{jitter_buffer_ms: 2_000}, to_string(user.id))
    Conversation.endpoint(pid, "what's on my calendar")
    # brain answer delivered -> brain_text set, turn enters :draining
    assert_receive {:to_client, {:speak_start, :brain, "the answer"}}, 1000

    Conversation.barge_in(pid)
    assert_receive {:to_client, :stop_playback}, 1000

    # the completed exchange is persisted (answered -> persist, not carried forward)
    wait_until(fn ->
      Enum.any?(App.Memory.recent_turns(user.id, 5), fn turn ->
        turn.user_text == "what's on my calendar" and turn.brain_text == "the answer"
      end)
    end)
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries <= 0 -> flunk("condition not met within ~1s")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  test "turn.start during playback + interruptions on + a partial with words triggers barge-in" do
    Application.put_env(:app, :fake_brain_done_ms, 5_000)
    on_exit(fn -> Application.put_env(:app, :fake_brain_done_ms, 0) end)
    stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "huh"} end)

    pid = start_conv()
    Conversation.set_allow_interruptions(pid, true)
    Conversation.endpoint(pid, "tell me a long story")
    assert_receive {:to_client, {:audio, :brain, _}}, 1000

    Conversation.turn_start(pid)
    Conversation.partial(pid, "actually wait")

    assert_receive {:to_client, :stop_playback}, 1000
    assert Process.alive?(pid)
  end

  test "a bare turn.start (no confirming words) does NOT barge in" do
    Application.put_env(:app, :fake_brain_done_ms, 5_000)
    on_exit(fn -> Application.put_env(:app, :fake_brain_done_ms, 0) end)
    stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "huh"} end)

    pid = start_conv()
    Conversation.set_allow_interruptions(pid, true)
    Conversation.endpoint(pid, "q")
    assert_receive {:to_client, {:audio, :brain, _}}, 1000

    Conversation.turn_start(pid)
    Conversation.partial(pid, "   ")
    refute_receive {:to_client, :stop_playback}, 300
  end

  test "turn.start does NOT barge in when interruptions are off" do
    Application.put_env(:app, :fake_brain_done_ms, 5_000)
    on_exit(fn -> Application.put_env(:app, :fake_brain_done_ms, 0) end)
    stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "huh"} end)

    pid = start_conv()
    Conversation.endpoint(pid, "q")
    assert_receive {:to_client, {:audio, :brain, _}}, 1000

    Conversation.turn_start(pid)
    Conversation.partial(pid, "actually wait")
    refute_receive {:to_client, :stop_playback}, 300
  end

  test "turn.start while idle (listening) never barges in even with interruptions on" do
    stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "huh"} end)
    pid = start_conv()
    Conversation.set_allow_interruptions(pid, true)

    Conversation.turn_start(pid)
    Conversation.partial(pid, "hello there")
    refute_receive {:to_client, :stop_playback}, 300
  end

  describe "brain prewarm" do
    test "turn_start pre-opens the brain; the endpoint adopts it (one start, correct transcript)" do
      Process.register(self(), :fake_brain_observer)
      stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "hm"} end)
      pid = start_conv()

      Conversation.turn_start(pid)
      assert_receive {:fake_brain_prewarmed}, 500

      Conversation.endpoint(pid, "what's the weather")
      assert_receive {:fake_brain_transcript, "what's the weather"}, 1000
      # exactly one fake brain was started
      refute_receive {:fake_brain_prewarmed}, 200
      assert_receive {:to_client, {:speak_start, :brain, _}}, 2000
    end

    test "an unused prewarm is killed by the TTL" do
      Process.register(self(), :fake_brain_observer)
      Application.put_env(:app, :prewarm_ttl_ms, 80)
      on_exit(fn -> Application.delete_env(:app, :prewarm_ttl_ms) end)
      pid = start_conv()

      Conversation.turn_start(pid)
      assert_receive {:fake_brain_prewarmed}, 500
      # after the TTL the prewarm dies; a later endpoint cold-starts a fresh brain
      Process.sleep(200)
      stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "hm"} end)
      Conversation.endpoint(pid, "hello")
      assert_receive {:fake_brain_transcript, "hello"}, 1000
    end

    test "no prewarm while wake-locked (ambient TV must not open a TTS socket every few seconds)" do
      Process.register(self(), :fake_brain_observer)
      pid = start_conv()
      Conversation.set_voice_activation(pid, true)
      assert_receive {:to_client, {:locked, true}}, 500

      Conversation.turn_start(pid)
      refute_receive {:fake_brain_prewarmed}, 300
    end
  end

  describe "duck-then-decide" do
    defp playback_turn(pid) do
      Application.put_env(:app, :fake_brain_done_ms, 600)
      on_exit(fn -> Application.delete_env(:app, :fake_brain_done_ms) end)
      stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "hm"} end)
      Conversation.set_allow_interruptions(pid, true)
      Conversation.endpoint(pid, "tell me a story")
      assert_receive {:to_client, {:speak_start, :reflex, _}}, 1000
    end

    test "onset ducks; wordless partial stays ducked; expiry unducks" do
      pid = start_conv()
      playback_turn(pid)

      Conversation.turn_start(pid)
      assert_receive {:to_client, :duck}, 500

      Conversation.partial(pid, "...")
      refute_receive {:to_client, :unduck}, 100
      refute_receive {:to_client, :stop_playback}, 100

      # the 2s interrupt window expires -> unduck (no interruption)
      assert_receive {:to_client, :unduck}, 2500
    end

    test "backchannel unducks and does NOT stop; escalation in the same window stops" do
      pid = start_conv()
      playback_turn(pid)

      Conversation.turn_start(pid)
      assert_receive {:to_client, :duck}, 500

      Conversation.partial(pid, "yeah")
      assert_receive {:to_client, :unduck}, 500
      refute_receive {:to_client, :stop_playback}, 200

      # Ink partials are cumulative — the same utterance grows into a real interruption
      Conversation.partial(pid, "yeah but actually stop")
      assert_receive {:to_client, :stop_playback}, 500
    end

    test "real interruption stops playback (as before)" do
      pid = start_conv()
      playback_turn(pid)

      Conversation.turn_start(pid)
      assert_receive {:to_client, :duck}, 500
      Conversation.partial(pid, "wait what about tomorrow")
      assert_receive {:to_client, :stop_playback}, 500
    end

    test "no duck while wake-locked (safety stop owns locked mode)" do
      pid = start_conv()
      playback_turn(pid)
      Conversation.set_voice_activation(pid, true)
      assert_receive {:to_client, {:locked, true}}, 500

      Conversation.turn_start(pid)
      refute_receive {:to_client, :duck}, 300
    end

    test "watchdog abort while ducked unducks the client (no stuck-quiet)" do
      # brain never finishes generating before the short watchdog fires mid-stream while ducked.
      Application.put_env(:app, :fake_brain_done_ms, 10_000)
      on_exit(fn -> Application.delete_env(:app, :fake_brain_done_ms) end)
      stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "hm"} end)

      pid = start_conv(%Config{turn_max_ms: 800})
      Conversation.set_allow_interruptions(pid, true)
      Conversation.endpoint(pid, "tell me a story")
      assert_receive {:to_client, {:speak_start, :reflex, _}}, 1000

      Conversation.turn_start(pid)
      assert_receive {:to_client, :duck}, 500

      # The watchdog (800ms) aborts the stuck turn mid-stream, BEFORE the 2s interrupt window.
      # Its teardown emits no stop_playback, so it must unduck the client itself — a :unduck
      # within 1500ms proves it came from the watchdog path, not the 2000ms window expiry.
      assert_receive {:to_client, :unduck}, 1500
      refute_receive {:to_client, :stop_playback}, 100
    end
  end

  defp start_conv_session(config \\ @config, session_id \\ "default") do
    {:ok, pid} =
      Conversation.start_link(client: self(), config: config, session_id: session_id, name: nil)

    pid
  end

  test "a due reminder is spoken when idle (canned lead + reminder audio)" do
    stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "huh"} end)
    pid = start_conv_session()
    send(pid, {:agenda_due, App.Agenda.reminder_item(%App.Reminders.Reminder{body: "call mom"})})

    assert_receive {:to_client, {:speak_start, :reminder, "Heads up —"}}, 1000
    assert_receive {:to_client, {:audio, :reminder, _}}, 1000
  end

  test "an idle reminder starts a reminder turn: canned lead, brain fulfills it, no you: line" do
    Process.register(self(), :fake_brain_observer)

    on_exit(fn ->
      if Process.whereis(:fake_brain_observer), do: Process.unregister(:fake_brain_observer)
    end)

    stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "huh"} end)

    pid = start_conv_session()

    send(
      pid,
      {:agenda_due, App.Agenda.reminder_item(%App.Reminders.Reminder{body: "check the weather"})}
    )

    assert_receive {:to_client, {:speak_start, :reminder, "Heads up —"}}, 1000
    assert_receive {:fake_brain_transcript, transcript}, 1000
    assert transcript =~ "check the weather"
    assert transcript =~ ~r/reminder/i
    refute_receive {:to_client, {:transcript, _}}, 200
  end

  test "a due reminder is NOT spoken mid-turn" do
    Application.put_env(:app, :fake_brain_done_ms, 5_000)
    on_exit(fn -> Application.put_env(:app, :fake_brain_done_ms, 0) end)
    stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "huh"} end)

    pid = start_conv_session()
    Conversation.endpoint(pid, "q")
    assert_receive {:to_client, {:audio, :brain, _}}, 1000

    send(pid, {:agenda_due, App.Agenda.reminder_item(%App.Reminders.Reminder{body: "x"})})
    refute_receive {:to_client, {:speak_start, :reminder, _}}, 300
  end

  test "a reminder turn fulfills with recent conversation context stripped" do
    Process.register(self(), :fake_brain_observer)

    on_exit(fn ->
      if Process.whereis(:fake_brain_observer), do: Process.unregister(:fake_brain_observer)
    end)

    stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "huh"} end)

    pid = start_conv_session()

    send(
      pid,
      {:agenda_due, App.Agenda.reminder_item(%App.Reminders.Reminder{body: "check the weather"})}
    )

    assert_receive {:fake_brain_recent_context, false}, 1000
  end

  test "the brain turn emits a :thinking signal to the client" do
    stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "huh"} end)
    pid = start_conv()
    Conversation.endpoint(pid, "q")
    assert_receive {:to_client, :thinking}, 1000
  end

  test "a normal user turn keeps recent conversation context" do
    Process.register(self(), :fake_brain_observer)

    on_exit(fn ->
      if Process.whereis(:fake_brain_observer), do: Process.unregister(:fake_brain_observer)
    end)

    stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "huh"} end)

    pid = start_conv_session()
    Conversation.endpoint(pid, "hello there")

    assert_receive {:fake_brain_recent_context, true}, 1000
  end

  test "a mid-turn reminder is queued and interjected as a reminder turn after completion" do
    Application.put_env(:app, :fake_brain_done_ms, 200)
    on_exit(fn -> Application.put_env(:app, :fake_brain_done_ms, 0) end)
    stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "huh"} end)

    pid = start_conv_session()
    Conversation.endpoint(pid, "q")
    # fire while the first turn is in flight -> queued
    send(pid, {:agenda_due, App.Agenda.reminder_item(%App.Reminders.Reminder{body: "call mom"})})

    # after the first turn completes, the queued reminder is delivered as its own turn
    assert_receive {:to_client, {:speak_start, :reminder, "Oh, before I forget —"}}, 3000
  end

  test "ptt_release finalizes the STT when listening" do
    Process.register(self(), :fake_stt_observer)

    on_exit(fn ->
      if Process.whereis(:fake_stt_observer), do: Process.unregister(:fake_stt_observer)
    end)

    stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "huh"} end)

    pid = start_conv_session()
    Conversation.ptt_release(pid)

    assert_receive {:fake_stt_finalize}, 1000
  end

  test "ptt_release is ignored mid-turn (not listening)" do
    Application.put_env(:app, :fake_brain_done_ms, 5_000)
    on_exit(fn -> Application.put_env(:app, :fake_brain_done_ms, 0) end)

    Process.register(self(), :fake_stt_observer)

    on_exit(fn ->
      if Process.whereis(:fake_stt_observer), do: Process.unregister(:fake_stt_observer)
    end)

    stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "huh"} end)

    pid = start_conv_session()
    Conversation.endpoint(pid, "q")
    assert_receive {:to_client, {:audio, :brain, _}}, 1000

    Conversation.ptt_release(pid)
    refute_receive {:fake_stt_finalize}, 300
  end

  test "PTT press while Henry is responding barges in (takes the floor), so the release finalizes" do
    # keep the brain busy so Henry is still mid-response when we press again
    Application.put_env(:app, :fake_brain_done_ms, 5_000)
    on_exit(fn -> Application.put_env(:app, :fake_brain_done_ms, 0) end)

    Process.register(self(), :fake_stt_observer)

    on_exit(fn ->
      if Process.whereis(:fake_stt_observer), do: Process.unregister(:fake_stt_observer)
    end)

    stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "the answer"} end)

    pid = start_conv_session()
    Conversation.set_ptt(pid, true)
    assert_receive {:fake_stt_started, :manual}, 1000

    # First PTT turn → Henry starts responding (phase leaves :listening).
    Conversation.ptt_press(pid)
    Conversation.ptt_release(pid)
    assert_receive {:fake_stt_finalize}, 1000
    Conversation.endpoint(pid, "first question")
    assert_receive {:to_client, {:audio, _src, _}}, 1000

    # Press PTT again WHILE Henry is talking. This must take the floor (barge-in) and return to
    # listening, so the *release* finalizes — instead of being silently dropped, which orphaned the
    # audio in the manual STT buffer and merged "previous + current" speech onto a later release.
    Conversation.ptt_press(pid)
    assert_receive {:to_client, :stop_playback}, 1000
    Conversation.ptt_release(pid)
    assert_receive {:fake_stt_finalize}, 1000
  end

  test "PTT mode ignores ambient partials and auto-endpoints" do
    Process.register(self(), :fake_stt_observer)

    on_exit(fn ->
      if Process.whereis(:fake_stt_observer), do: Process.unregister(:fake_stt_observer)
    end)

    stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "huh"} end)

    pid = start_conv_session()
    Conversation.set_ptt(pid, true)

    Conversation.partial(pid, "someone across the room")
    refute_receive {:to_client, {:partial, _}}, 200

    Conversation.endpoint(pid, "ambient sentence")
    refute_receive {:to_client, {:speak_start, :reflex, _}}, 300
  end

  test "PTT toggle reconnects STT in manual mode; release finalizes; the endpoint runs a turn" do
    Process.register(self(), :fake_stt_observer)

    on_exit(fn ->
      if Process.whereis(:fake_stt_observer), do: Process.unregister(:fake_stt_observer)
    end)

    stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "huh"} end)

    pid = start_conv_session()
    Conversation.set_ptt(pid, true)
    assert_receive {:fake_stt_started, :manual}, 1000

    Conversation.ptt_press(pid)
    Conversation.ptt_release(pid)
    assert_receive {:fake_stt_finalize}, 1000

    Conversation.endpoint(pid, "do the thing")
    assert_receive {:to_client, {:speak_start, :reflex, _}}, 1000
  end

  test "toggling PTT off reconnects the STT back to auto (hands-free) mode" do
    Process.register(self(), :fake_stt_observer)

    on_exit(fn ->
      if Process.whereis(:fake_stt_observer), do: Process.unregister(:fake_stt_observer)
    end)

    stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "huh"} end)

    pid = start_conv_session()
    Conversation.set_ptt(pid, true)
    assert_receive {:fake_stt_started, :manual}, 1000

    Conversation.set_ptt(pid, false)
    assert_receive {:fake_stt_started, :auto}, 1000
  end

  test "PTT: a new press clears a stuck expecting_finalize (empty-release self-heal)" do
    Process.register(self(), :fake_stt_observer)

    on_exit(fn ->
      if Process.whereis(:fake_stt_observer), do: Process.unregister(:fake_stt_observer)
    end)

    stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "huh"} end)

    pid = start_conv_session()
    Conversation.set_ptt(pid, true)
    assert_receive {:fake_stt_started, :manual}, 1000

    # zero-speech release leaves expecting_finalize set (Ink returns no endpoint)
    Conversation.ptt_release(pid)
    assert_receive {:fake_stt_finalize}, 1000

    # a fresh press must clear it, so a subsequent AUTO endpoint is still ignored
    Conversation.ptt_press(pid)
    Conversation.endpoint(pid, "ambient after press")
    refute_receive {:to_client, {:speak_start, :reflex, _}}, 300
  end

  test "eager_end pre-computes the reflex silently (no speak_start, no thinking, while listening)" do
    stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "huh"} end)

    pid = start_conv_session()
    Conversation.eager_end(pid, "what's the weather")

    refute_receive {:to_client, {:speak_start, _src, _text}}, 300
    refute_receive {:to_client, :thinking}, 300
  end

  test "eager_end then endpoint speaks the reflex with exactly ONE model call (head-start)" do
    # Count only :reflex-tier generates (the memory updater also calls the model, at a different
    # tier — filtering keeps this immune to that). Exactly one proves the endpoint reused the
    # speculative result rather than re-generating.
    test_pid = self()

    stub(App.TextModelMock, :generate, fn _t, _c, opts ->
      if Keyword.get(opts, :tier) == :reflex, do: send(test_pid, :reflex_generate)
      {:ok, "huh, okay"}
    end)

    pid = start_conv_session()
    Conversation.eager_end(pid, "whats the weather")
    Conversation.endpoint(pid, "what's the weather")

    assert_receive {:to_client, {:speak_start, :reflex, "huh, okay"}}, 1000
    assert_receive :reflex_generate, 1000
    refute_receive :reflex_generate, 300
  end

  test "resume cancels the speculative reflex; a later real turn still works" do
    stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "huh"} end)

    pid = start_conv_session()
    Conversation.eager_end(pid, "maybe umm")
    Conversation.resume(pid)
    refute_receive {:to_client, {:speak_start, _src, _text}}, 300

    Conversation.endpoint(pid, "actually do it")
    assert_receive {:to_client, {:speak_start, :reflex, _}}, 1000
  end

  test "eager_reflex: false makes eager_end a no-op (no early model call)" do
    # Exactly one :reflex-tier generate — the normal one at endpoint. If eager_end (toggled off)
    # wrongly spawned a model task, we'd see two :reflex_generate messages.
    test_pid = self()

    stub(App.TextModelMock, :generate, fn _t, _c, opts ->
      if Keyword.get(opts, :tier) == :reflex, do: send(test_pid, :reflex_generate)
      {:ok, "huh"}
    end)

    pid = start_conv_session(%Config{eager_reflex: false})
    Conversation.eager_end(pid, "hello")
    Conversation.endpoint(pid, "hello")

    assert_receive {:to_client, {:speak_start, :reflex, "huh"}}, 1000
    assert_receive :reflex_generate, 1000
    refute_receive :reflex_generate, 300
  end

  test "endpoint while the speculative reflex is still running adopts it (one call, still speaks)" do
    # Block the speculative Gemini call so the endpoint provably lands while the task is :running,
    # forcing the adopt branch. Then release it and confirm it's spoken with exactly one call.
    test_pid = self()

    stub(App.TextModelMock, :generate, fn _t, _c, opts ->
      if Keyword.get(opts, :tier) == :reflex do
        send(test_pid, {:reflex_generate, self()})

        receive do
          :release -> :ok
        after
          2000 -> :ok
        end
      end

      {:ok, "huh, okay"}
    end)

    pid = start_conv_session()
    Conversation.eager_end(pid, "whats the weather")
    assert_receive {:reflex_generate, gen_pid}, 1000

    # endpoint arrives while the speculative call is still blocked → the :running adopt branch
    Conversation.endpoint(pid, "what's the weather")
    send(gen_pid, :release)

    assert_receive {:to_client, {:speak_start, :reflex, "huh, okay"}}, 1000
    refute_receive {:reflex_generate, _}, 300
  end

  test "toggling PTT clears an in-flight speculative reflex (no stale head-start leaks in)" do
    test_pid = self()

    stub(App.TextModelMock, :generate, fn t, _c, opts ->
      if Keyword.get(opts, :tier) == :reflex, do: send(test_pid, :reflex_generate)
      {:ok, "ok:" <> t}
    end)

    pid = start_conv_session()
    # an auto-mode eager_end starts a speculative reflex computed from the auto transcript...
    Conversation.eager_end(pid, "auto utterance")
    assert_receive :reflex_generate, 1000

    # ...then the user flips to PTT before the auto turn endpoints. The stale speculation must be
    # dropped, so the PTT turn speaks a FRESH reflex (computed from the PTT transcript), not the
    # auto one. If the slot leaked, this would be "ok:auto utterance".
    Conversation.set_ptt(pid, true)
    Conversation.ptt_press(pid)
    Conversation.ptt_release(pid)
    Conversation.endpoint(pid, "ptt utterance")

    assert_receive {:to_client, {:speak_start, :reflex, "ok:ptt utterance"}}, 1000
  end

  test "race mode: a fast brain skips the slow reflex entirely" do
    stub(App.TextModelMock, :generate, fn _t, _c, opts ->
      # the reflex model call is slow — the fake brain's audio will win
      if Keyword.get(opts, :tier) == :reflex, do: Process.sleep(500)
      {:ok, "late reflex"}
    end)

    pid = start_conv(%Config{reflex_mode: :race})
    Conversation.endpoint(pid, "quick question")

    assert_receive {:to_client, {:audio, :brain, _}}, 2000
    assert_receive {:to_client, {:speak_start, :brain, _}}, 2000
    refute_receive {:to_client, {:speak_start, :reflex, _}}, 600
  end

  describe "agenda framework" do
    alias App.Agenda.Item

    test "an :after_next_turn item waits while idle, then interjects after the next user turn" do
      stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "hm"} end)
      pid = start_conv()

      item = %Item{
        kind: :briefing,
        prompt: "give the briefing",
        deliver: :after_next_turn,
        lead_interjected: "Oh — your morning rundown:"
      }

      send(pid, {:agenda_due, item})
      # idle, but it must NOT self-start
      refute_receive {:to_client, {:speak_start, :briefing, _}}, 400

      # a user turn runs and completes -> the item interjects
      Conversation.endpoint(pid, "hello there")
      assert_receive {:to_client, {:speak_start, :briefing, "Oh — your morning rundown:"}}, 3000
    end

    test "an expired item is dropped at delivery, never spoken" do
      # The drop line logs at :info, but the test env's primary Logger level is :warning
      # (config/test.exs), which filters :info before ANY handler (incl. CaptureLog) sees it.
      # Bump the primary level for this one test so the :info line is capturable (async: false
      # makes this global mutation safe); restore it on exit.
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)

      pid = start_conv()

      item = %Item{
        kind: :briefing,
        prompt: "stale briefing",
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(pid, {:agenda_due, item})
          refute_receive {:to_client, {:speak_start, _, _}}, 300
        end)

      assert log =~ "[agenda] expired, dropped: briefing"
    end

    test "persist_as: the completed agenda turn is stored with the given user_text" do
      # start_conv/1 has no session_id, so persistence is normally skipped; use a session
      {:ok, pid} =
        Conversation.start_link(
          client: self(),
          config: @config,
          name: nil,
          session_id: session_id_for_test_user()
        )

      item = %Item{kind: :briefing, prompt: "give the briefing", persist_as: "(morning briefing)"}
      send(pid, {:agenda_due, item})
      assert_receive {:to_client, {:speak_start, :briefing, _lead}}, 1000
      assert_receive {:to_client, {:speak_start, :brain, answer}}, 2000

      # wait out the drain (fake audio ~10ms + 150ms jitter) then check the row landed
      Process.sleep(400)
      turns = App.Memory.recent_turns(user_id_for_test_user(), 5)
      assert Enum.any?(turns, &(&1.user_text == "(morning briefing)" and &1.brain_text == answer))
    end

    test "a briefing is de-duped: a second :agenda_due while one is pending doesn't double-speak" do
      stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "hm"} end)
      pid = start_conv()

      item = %Item{
        kind: :briefing,
        prompt: "give the briefing",
        deliver: :after_next_turn,
        lead_interjected: "Rundown:"
      }

      send(pid, {:agenda_due, item})
      send(pid, {:agenda_due, item})

      Conversation.endpoint(pid, "hello")
      assert_receive {:to_client, {:speak_start, :briefing, "Rundown:"}}, 3000
      # only ONE briefing turn — the duplicate was dropped at receipt
      refute_receive {:to_client, {:speak_start, :briefing, _}}, 600
    end

    test "pull-on-connect: a Conversation whose user is due self-injects the briefing" do
      Application.put_env(:app, :allowed_users, [%{email: "agenda@x.com", name: "Agenda Test"}])
      on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
      {:ok, user} = App.Users.upsert_allowed("agenda@x.com")
      now_hhmm = Calendar.strftime(DateTime.now!(App.Config.timezone()), "%H:%M")
      {:ok, _} = App.Users.update_prefs(user, %{briefing_time: now_hhmm})

      stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "hm"} end)

      {:ok, pid} =
        Conversation.start_link(
          client: self(),
          config: @config,
          name: nil,
          session_id: to_string(user.id)
        )

      # no manual :agenda_due — the pull on start queues it; the first user turn delivers it
      Conversation.endpoint(pid, "morning")

      assert_receive {:to_client,
                      {:speak_start, :briefing, "Oh — and here's your morning rundown."}},
                     3000
    end
  end

  describe "heard-fraction persistence" do
    test "truncate_heard/2 (pure)" do
      text = "The quick brown fox jumps over the lazy dog and keeps on running home."

      assert Conversation.truncate_heard(text, 1.0) == text
      assert Conversation.truncate_heard(text, 0.96) == text

      half = Conversation.truncate_heard(text, 0.5)
      assert String.ends_with?(half, " —[interrupted]")
      prefix = String.replace_suffix(half, " —[interrupted]", "")
      assert String.starts_with?(text, prefix)
      # snapped to a word boundary: the prefix must not end mid-word
      refute String.ends_with?(prefix, ["qui", "bro", "fo"])
      assert String.length(prefix) < String.length(text)

      assert Conversation.truncate_heard(text, 0.0) == "—[interrupted]"
    end

    test "a barged answered turn waits for the played report and persists truncated" do
      Application.put_env(:app, :fake_brain_done_ms, 150)
      on_exit(fn -> Application.delete_env(:app, :fake_brain_done_ms) end)
      stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "hm"} end)

      {:ok, pid} =
        Conversation.start_link(
          client: self(),
          config: @config,
          name: nil,
          session_id: session_id_for_test_user()
        )

      Conversation.set_allow_interruptions(pid, true)
      Conversation.endpoint(pid, "tell me a story")
      # wait until the brain has answered (draining) so the barge hits the answered path
      assert_receive {:to_client, {:speak_start, :brain, _answer}}, 2000

      Conversation.turn_start(pid)
      Conversation.partial(pid, "wait stop that")
      assert_receive {:to_client, :stop_playback}, 500

      # client reports it played almost nothing of the brain audio
      Conversation.played(pid, 1)
      Process.sleep(300)

      turns = App.Memory.recent_turns(user_id_for_test_user(), 3)
      assert Enum.any?(turns, &(is_binary(&1.brain_text) and &1.brain_text =~ "—[interrupted]"))
    end

    test "no played report -> 500ms fallback persists the full text" do
      Application.put_env(:app, :fake_brain_done_ms, 150)
      on_exit(fn -> Application.delete_env(:app, :fake_brain_done_ms) end)
      stub(App.TextModelMock, :generate, fn _t, _c, _o -> {:ok, "hm"} end)

      {:ok, pid} =
        Conversation.start_link(
          client: self(),
          config: @config,
          name: nil,
          session_id: session_id_for_test_user()
        )

      Conversation.set_allow_interruptions(pid, true)
      Conversation.endpoint(pid, "tell me a story")
      assert_receive {:to_client, {:speak_start, :brain, answer}}, 2000

      Conversation.turn_start(pid)
      Conversation.partial(pid, "wait stop that")
      assert_receive {:to_client, :stop_playback}, 500

      Process.sleep(800)
      turns = App.Memory.recent_turns(user_id_for_test_user(), 3)
      assert Enum.any?(turns, &(&1.brain_text == answer))
    end
  end

  # Real user row (allowlisted + upserted), same pattern as the barge-in persistence test above —
  # session_id is `to_string(user.id)` so App.Users.id_from_session/1 resolves it back.
  defp user_id_for_test_user do
    Application.put_env(:app, :allowed_users, [%{email: "agenda@x.com", name: "Agenda Test"}])
    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, user} = App.Users.upsert_allowed("agenda@x.com")
    user.id
  end

  defp session_id_for_test_user, do: to_string(user_id_for_test_user())
end
