defmodule App.Speaker.GateTest do
  use ExUnit.Case, async: true
  alias App.Speaker.Gate

  @base %{
    score: nil,
    speech_ms: 3_000,
    last_verified_ms_ago: nil,
    threshold: 0.40,
    min_verify_ms: 1_200,
    trust_window_ms: 15_000
  }

  test "decision table" do
    for {overrides, expected} <- [
          # long enough to verify: score decides
          {%{score: 0.75}, {:pass, :verified}},
          {%{score: 0.40}, {:pass, :verified}},
          {%{score: 0.39}, {:drop, :below_threshold}},
          {%{score: -0.2}, {:drop, :below_threshold}},
          # short turn: trust window decides, score ignored
          {%{speech_ms: 800, last_verified_ms_ago: 5_000}, {:pass, :trusted}},
          {%{speech_ms: 800, last_verified_ms_ago: 15_000}, {:pass, :trusted}},
          {%{speech_ms: 800, last_verified_ms_ago: 15_001}, {:drop, :short_no_trust}},
          {%{speech_ms: 800, last_verified_ms_ago: nil}, {:drop, :short_no_trust}},
          {%{speech_ms: 1_199, last_verified_ms_ago: nil}, {:drop, :short_no_trust}},
          {%{speech_ms: 1_200, score: 0.5}, {:pass, :verified}}
        ] do
      assert Gate.decide(Map.merge(@base, overrides)) == expected,
             "params #{inspect(overrides)}"
    end
  end

  test "score/2 is the dot product of normalized vectors" do
    assert_in_delta Gate.score([1.0, 0.0], [1.0, 0.0]), 1.0, 1.0e-9
    assert_in_delta Gate.score([1.0, 0.0], [0.0, 1.0]), 0.0, 1.0e-9
    assert_in_delta Gate.score([0.6, 0.8], [0.6, 0.8]), 1.0, 1.0e-9
  end
end
