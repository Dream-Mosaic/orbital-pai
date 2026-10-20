defmodule App.HomeAssistant.PhrasesTest do
  # HA tests stay async: false (they share global app env and the published phrases).
  use ExUnit.Case, async: false

  alias App.HomeAssistant
  alias App.HomeAssistant.{Directory, Phrases}
  alias App.Test.HomeFixture

  setup do
    Application.delete_env(:app, :home_assistant_directory)
    HomeAssistant.forget_phrases()

    on_exit(fn ->
      Application.delete_env(:app, :home_assistant_directory)
      HomeAssistant.forget_phrases()
    end)
  end

  test "names with their device tail cut, aliases and areas, normalized" do
    dir =
      Directory.build(
        HomeFixture.with_alias("light.pantry_lighy", "Snack Closet!"),
        ~U[2026-10-19 20:00:00Z]
      )

    phrases = Phrases.from_directory(dir)
    assert "dining table" in phrases
    assert "gaming" in phrases
    assert "fireplace" in phrases
    assert "snack closet" in phrases
    assert "game room" in phrases
    assert "living room" in phrases
    # too short to be a name worth matching on its own
    refute Enum.any?(phrases, &(String.length(&1) < 4))
    assert phrases == Enum.sort(Enum.uniq(phrases))
  end

  test "normalize/1: lowercase words, punctuation runs to one space" do
    assert Phrases.normalize("  Turn on the GAMING-lights, please! ") ==
             "turn on the gaming lights please"
  end

  test "phrases/0 is [] until a build publishes them; publishing an unchanged list is a no-op" do
    assert HomeAssistant.phrases() == []

    assert HomeAssistant.publish_phrases(["gaming"]) == :ok
    assert HomeAssistant.phrases() == ["gaming"]
    assert HomeAssistant.publish_phrases(["gaming"]) == :unchanged
    assert HomeAssistant.publish_phrases(["gaming", "fireplace"]) == :ok
  end

  test "the :home_assistant_directory seam wins (a directory, or a fun returning one)" do
    HomeAssistant.publish_phrases(["stale"])
    dir = HomeFixture.directory()

    Application.put_env(:app, :home_assistant_directory, dir)
    assert "gaming" in HomeAssistant.phrases()

    Application.put_env(:app, :home_assistant_directory, fn -> {:ok, dir} end)
    assert "gaming" in HomeAssistant.phrases()

    Application.put_env(:app, :home_assistant_directory, fn -> {:error, :not_loaded} end)
    assert HomeAssistant.phrases() == []
  end
end
