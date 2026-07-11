defmodule App.Conversations.LookIntentTest do
  use ExUnit.Case, async: true
  alias App.Conversations.LookIntent
  alias App.Config

  @cfg %Config{}

  test "matches the canonical look phrases (case-insensitive)" do
    assert LookIntent.wants_look?("Henry, look at this, what is it?", @cfg)
    assert LookIntent.wants_look?("LOOK AT THAT", @cfg)
    assert LookIntent.wants_look?("can you see this?", @cfg)
    assert LookIntent.wants_look?("check this out", @cfg)
    assert LookIntent.wants_look?("read this label for me", @cfg)
    assert LookIntent.wants_look?("what's this?", @cfg)
    assert LookIntent.wants_look?("take a look at this", @cfg)
  end

  test "does not match ordinary utterances" do
    refute LookIntent.wants_look?("what's the weather like", @cfg)
    refute LookIntent.wants_look?("remind me to call mom at five", @cfg)
    refute LookIntent.wants_look?("I was looking at the news earlier", @cfg)
    refute LookIntent.wants_look?("", @cfg)
  end

  test "is total — non-binary input is a no-op, never raises" do
    refute LookIntent.wants_look?(nil, @cfg)
  end
end
