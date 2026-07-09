defmodule App.Conversations.WakeWordTest do
  use ExUnit.Case, async: true

  alias App.Conversations.WakeWord
  alias App.Config

  @cfg %Config{}

  describe "match/2 — prefix + name (anywhere)" do
    test "wake up + name, mid-blob, strips everything through the trigger" do
      assert {:wake, "what's the weather?"} =
               WakeWord.match("and the game ended, wake up Henry, what's the weather?", @cfg)
    end

    test "hey + name with a comma between" do
      assert {:wake, "lights please"} = WakeWord.match("hey, Henry lights please", @cfg)
    end

    test "okay/ok prefixes" do
      assert {:wake, "hello"} = WakeWord.match("okay Henry hello", @cfg)
      assert {:wake, "hello"} = WakeWord.match("ok Henry hello", @cfg)
    end

    test "a word ENDING in a prefix does not count (boundary)" do
      # "donkey Henry" must not match the "key"→"hey"-ish tail of another word
      assert :none = WakeWord.match("I saw a donkey Henry drew", @cfg)
      # "book" ends in the "ok" prefix — this genuinely reaches boundary_before?/2,
      # which must reject it because the char before "ok" ('o') is a word char.
      assert :none = WakeWord.match("I read a book Henry wrote", @cfg)
    end
  end

  describe "match/2 — vocative (sentence-leading) name" do
    test "at the very start" do
      assert {:wake, "what's the weather"} = WakeWord.match("Henry, what's the weather", @cfg)
    end

    test "right after a sentence boundary" do
      assert {:wake, "what's up"} = WakeWord.match("the game ended. Henry what's up", @cfg)
      assert {:wake, "hi"} = WakeWord.match("no way! Henry hi", @cfg)
      assert {:wake, "hi"} = WakeWord.match("really? Henry hi", @cfg)
    end

    test "mid-sentence third-person mention does NOT wake" do
      assert :none = WakeWord.match("I think Henry got it wrong", @cfg)
      assert :none = WakeWord.match("what's the weather, Henry?", @cfg)
    end

    test "bare name -> empty rest" do
      assert {:wake, ""} = WakeWord.match("Henry", @cfg)
      assert {:wake, ""} = WakeWord.match("Henry.", @cfg)
    end

    test "first trigger wins" do
      assert {:wake, "one. Henry two"} = WakeWord.match("Henry one. Henry two", @cfg)
    end
  end

  describe "match/2 — fuzzy + aliases" do
    test "Levenshtein distance 1 on the name matches" do
      assert {:wake, "hello"} = WakeWord.match("Henri, hello", @cfg)
      assert {:wake, "hello"} = WakeWord.match("Hendry hello", %{@cfg | wake_prefixes: []})
    end

    test "short or far tokens never fuzzy-match" do
      assert :none = WakeWord.match("the hen is loose", @cfg)
      assert :none = WakeWord.match("I am hungry today", @cfg)
      assert :none = WakeWord.match("henrietta called", @cfg)
    end

    test "wake_fuzzy: false reverts to exact + aliases" do
      cfg = %{@cfg | wake_fuzzy: false}
      assert :none = WakeWord.match("Henri, hello", cfg)
      assert {:wake, "hello"} = WakeWord.match("Henry, hello", cfg)
    end

    test "aliases match exactly, word-boundary, including multi-word" do
      cfg = %{@cfg | wake_fuzzy: false, wake_aliases: ["on ree"]}
      assert {:wake, "what time is it"} = WakeWord.match("on ree what time is it", cfg)
      assert :none = WakeWord.match("carry on reeling", cfg)
    end

    test "case-insensitive everywhere" do
      assert {:wake, "hi"} = WakeWord.match("HENRY hi", @cfg)
      assert {:wake, "hi"} = WakeWord.match("WAKE UP henry hi", @cfg)
    end
  end

  describe "command_rest/1" do
    test "bare command" do
      assert {:command, ""} = WakeWord.command_rest("stop")
      assert {:command, ""} = WakeWord.command_rest("Stop.")
      assert {:command, ""} = WakeWord.command_rest("hold on")
      assert {:command, ""} = WakeWord.command_rest("never mind")
    end

    test "command + tail returns the tail" do
      assert {:command, "what's the time"} = WakeWord.command_rest("stop, what's the time")
      assert {:command, "a second"} = WakeWord.command_rest("wait a second")
    end

    test "non-commands and prefixes of longer words" do
      assert :none = WakeWord.command_rest("what's the weather")
      assert :none = WakeWord.command_rest("stopwatch please")
      assert :none = WakeWord.command_rest("")
    end
  end

  describe "sleep_command?/2" do
    test "bare sleep words (with optional trailing punctuation)" do
      assert WakeWord.sleep_command?("sleep", @cfg)
      assert WakeWord.sleep_command?("Sleep.", @cfg)
      assert WakeWord.sleep_command?("lock", @cfg)
      assert WakeWord.sleep_command?("go to sleep", @cfg)
      assert WakeWord.sleep_command?("go back to sleep", @cfg)
    end

    test "a sleep word with an (ignored) tail still counts" do
      assert WakeWord.sleep_command?("sleep now please", @cfg)
      assert WakeWord.sleep_command?("go to sleep buddy", @cfg)
    end

    test "non-sleep or boundary-violating rests do not count" do
      refute WakeWord.sleep_command?("sleeping in", @cfg)
      refute WakeWord.sleep_command?("locket", @cfg)
      refute WakeWord.sleep_command?("what's the weather", @cfg)
      refute WakeWord.sleep_command?("stop", @cfg)
      refute WakeWord.sleep_command?("", @cfg)
    end

    test "honors a custom sleep_words list" do
      cfg = %{@cfg | sleep_words: ["nap"]}
      assert WakeWord.sleep_command?("nap", cfg)
      refute WakeWord.sleep_command?("sleep", cfg)
    end
  end

  describe "levenshtein/2" do
    test "distances" do
      assert WakeWord.levenshtein("henry", "henry") == 0
      assert WakeWord.levenshtein("henri", "henry") == 1
      assert WakeWord.levenshtein("hendry", "henry") == 1
      assert WakeWord.levenshtein("hungry", "henry") == 2
      assert WakeWord.levenshtein("", "henry") == 5
    end
  end
end
