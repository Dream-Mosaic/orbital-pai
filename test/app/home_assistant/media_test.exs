defmodule App.HomeAssistant.MediaTest do
  use ExUnit.Case, async: true

  alias App.HomeAssistant.Media

  defp mp(id, attrs, state \\ "idle"),
    do: %{"entity_id" => id, "state" => state, "attributes" => attrs}

  describe "ma_players/1" do
    test "keeps only media_players carrying the active_queue attribute (excludes native Sonos)" do
      states = [
        mp(
          "media_player.sonos_kitchen",
          %{"friendly_name" => "Sonos Kitchen", "active_queue" => "q1"},
          "playing"
        ),
        # native Sonos entity — no active_queue — must be excluded
        mp("media_player.office", %{"friendly_name" => "Office"}, "idle"),
        mp("light.kitchen", %{"friendly_name" => "Kitchen Light"}, "on")
      ]

      assert Media.ma_players(states) == [
               %{entity_id: "media_player.sonos_kitchen", name: "Sonos Kitchen", state: "playing"}
             ]
    end

    test "keeps media_title/media_artist when present" do
      states = [
        mp(
          "media_player.sonos_kitchen",
          %{
            "friendly_name" => "Sonos Kitchen",
            "active_queue" => "q1",
            "media_title" => "She Loves You",
            "media_artist" => "The Beatles"
          },
          "playing"
        )
      ]

      assert [player] = Media.ma_players(states)
      assert player.media_title == "She Loves You"
      assert player.media_artist == "The Beatles"
    end

    test "falls back to entity_id when there's no friendly_name" do
      states = [mp("media_player.arbol_maxtreme", %{"active_queue" => "q1"})]
      assert [%{name: "media_player.arbol_maxtreme"}] = Media.ma_players(states)
    end

    test "an active_queue value of nil still counts (the KEY is the marker, not its value)" do
      states = [mp("media_player.davids_macbook_pro", %{"active_queue" => nil}, "off")]
      assert [%{entity_id: "media_player.davids_macbook_pro"}] = Media.ma_players(states)
    end
  end

  describe "resolve_player/2" do
    @players [
      %{entity_id: "media_player.sonos_kitchen", name: "Sonos Kitchen", state: "idle"},
      %{entity_id: "media_player.sonos_basement", name: "Sonos Basement", state: "idle"}
    ]

    test "name given + a match → that player" do
      assert {:ok, p} = Media.resolve_player(@players, "kitchen")
      assert p.entity_id == "media_player.sonos_kitchen"
    end

    test "name given + no match → :none" do
      assert {:error, :none} = Media.resolve_player(@players, "garage")
    end

    test "no name + exactly one player → that one (unambiguous)" do
      assert {:ok, p} = Media.resolve_player([hd(@players)], nil)
      assert p.entity_id == "media_player.sonos_kitchen"
    end

    test "no name + multiple players → :ambiguous (never guess the room)" do
      assert {:error, :ambiguous} = Media.resolve_player(@players, nil)
    end
  end

  describe "play_media_data/3" do
    test "query becomes media_id; enqueue defaults to replace; media_type omitted when nil" do
      assert Media.play_media_data("The Beatles", nil, nil) ==
               %{media_id: "The Beatles", enqueue: "replace"}
    end

    test "media_type included when given; enqueue passed through" do
      assert Media.play_media_data("Hey Jude", "track", "next") ==
               %{media_id: "Hey Jude", media_type: "track", enqueue: "next"}
    end
  end
end
