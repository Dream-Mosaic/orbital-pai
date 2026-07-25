defmodule App.Conversations.BackchannelTest do
  use ExUnit.Case, async: true

  alias App.Conversations.Backchannel

  test "noise: no letters" do
    assert Backchannel.classify("") == :noise
    assert Backchannel.classify("…") == :noise
    assert Backchannel.classify("1 2") == :noise
    assert Backchannel.classify(nil) == :noise
  end

  test "backchannels: all tokens in the lexicon, <= 3 tokens" do
    for t <- [
          "uh huh",
          "yeah",
          "no way!",
          "OK",
          "wow",
          "mm hmm",
          "oh wow",
          "Really?",
          "haha nice"
        ] do
      assert Backchannel.classify(t) == :backchannel, "expected backchannel: #{t}"
    end
  end

  test "interrupts: any non-lexicon word, or too long" do
    for t <- [
          "no wait",
          "stop it",
          "what about tomorrow",
          "yeah but actually stop",
          "yeah yeah ok sure"
        ] do
      assert Backchannel.classify(t) == :interrupt, "expected interrupt: #{t}"
    end
  end
end
