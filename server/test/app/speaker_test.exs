defmodule App.SpeakerTest do
  use ExUnit.Case, async: false
  alias App.Speaker

  setup do
    App.DataCase.setup_sandbox(%{async: false})

    user =
      App.Repo.insert!(%App.Users.User{
        email: "spk#{System.unique_integer([:positive])}@t",
        name: "T"
      })

    on_exit(fn -> Application.delete_env(:app, :fake_verifier_embedding) end)
    %{user: user}
  end

  defp loud_pcm(seconds) do
    one = for _ <- 1..16_000, into: <<>>, do: <<1000::16-signed-little>>
    :binary.copy(one, seconds)
  end

  test "enroll_clip: quality gates then upsert; voiceprint is the normalized mean", %{user: u} do
    assert {:error, :too_short} = Speaker.enroll_clip(u.id, 1, loud_pcm(3))
    assert {:error, :too_quiet} = Speaker.enroll_clip(u.id, 1, :binary.copy(<<0, 0>>, 16_000 * 7))

    Application.put_env(:app, :fake_verifier_embedding, [1.0, 0.0, 0.0, 0.0])
    assert :ok = Speaker.enroll_clip(u.id, 1, loud_pcm(7))
    Application.put_env(:app, :fake_verifier_embedding, [0.0, 1.0, 0.0, 0.0])
    assert :ok = Speaker.enroll_clip(u.id, 2, loud_pcm(7))

    assert Speaker.enrolled_slots(u.id) == [1, 2]
    assert {:ok, vp} = Speaker.voiceprint(u.id)
    # mean of two orthonormal vectors, renormalized -> [~0.707, ~0.707, 0, 0]
    assert_in_delta Enum.at(vp, 0), 0.7071, 0.001
    assert_in_delta Enum.at(vp, 1), 0.7071, 0.001
    # re-enrolling a slot replaces it (upsert)
    assert :ok = Speaker.enroll_clip(u.id, 2, loud_pcm(7))
    assert Speaker.enrolled_slots(u.id) == [1, 2]
  end

  test "voice_lock_state reflects prefs; set_mode persists + broadcasts", %{user: u} do
    Phoenix.PubSub.subscribe(App.PubSub, "voice_lock:#{u.id}")
    assert %{mode: :off, voiceprint: nil} = Speaker.voice_lock_state(u.id)
    assert {:ok, _} = Speaker.set_mode(u, "shadow")
    assert_receive {:voice_lock_changed}
    assert %{mode: :shadow} = Speaker.voice_lock_state(App.Users.get(u.id).id)
    assert {:ok, _} = Speaker.set_mode(u, "enforce")
    assert %{mode: :enforce} = Speaker.voice_lock_state(u.id)
  end

  test "log_event prunes to newest 100; recent_drops filters", %{user: u} do
    for i <- 1..105 do
      decision = if rem(i, 2) == 0, do: "pass", else: "would_drop"

      :ok =
        Speaker.log_event(%{
          user_id: u.id,
          decision: decision,
          reason: "below_threshold",
          score: 0.1,
          speech_ms: 2000,
          transcript: "t#{i}",
          mode: "shadow"
        })
    end

    import Ecto.Query

    assert App.Repo.aggregate(from(e in App.Speaker.GateEvent, where: e.user_id == ^u.id), :count) ==
             100

    drops = Speaker.recent_drops(u.id, 20)
    assert length(drops) == 20
    assert Enum.all?(drops, &(&1.decision == "would_drop"))
  end
end
