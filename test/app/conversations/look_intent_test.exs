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

  test "matches camera-framed requests that v1 missed (live-smoke gap)" do
    # From the wall kiosk log: "take a picture of this." fell through to a no-camera turn and the
    # brain said "I can't access your camera." These natural phrasings must fire a capture now.
    assert LookIntent.wants_look?("take a picture of this.", @cfg)
    assert LookIntent.wants_look?("take a photo", @cfg)
    assert LookIntent.wants_look?("can you take a pic of this", @cfg)
    assert LookIntent.wants_look?("snap a photo of this", @cfg)
    assert LookIntent.wants_look?("look at something for me", @cfg)
    assert LookIntent.wants_look?("look here", @cfg)
    assert LookIntent.wants_look?("what do you see", @cfg)
    assert LookIntent.wants_look?("what can you see here", @cfg)
    assert LookIntent.wants_look?("what am I holding", @cfg)
    assert LookIntent.wants_look?("what am I looking at", @cfg)
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
