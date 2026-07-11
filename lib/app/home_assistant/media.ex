defmodule App.HomeAssistant.Media do
  @moduledoc """
  Pure Music-Assistant player resolution for the `play_music` tool — no I/O. Music Assistant
  creates its OWN media_player entities (distinct from native integrations like Sonos) and
  marks them with an `active_queue` attribute — the ONLY reliable way to tell an MA player
  apart from a native one via `/api/states`. MA players carry no HA area, so callers resolve
  them by NAME (`App.HomeAssistant.Entities.match_name/2`), never by area.
  """

  alias App.HomeAssistant.Entities

  @doc """
  Raw `/api/states` entities → Music Assistant players only (an `active_queue` KEY in
  `attributes` — its value doesn't matter, an idle player can carry `active_queue: nil`),
  compacted to `{entity_id, name, state, media_title?, media_artist?}` (nils dropped).
  """
  def ma_players(states) when is_list(states) do
    states
    |> Enum.filter(&ma_player?/1)
    |> Enum.map(&compact/1)
  end

  defp ma_player?(%{"entity_id" => "media_player." <> _, "attributes" => attrs})
       when is_map(attrs),
       do: Map.has_key?(attrs, "active_queue")

  defp ma_player?(_), do: false

  defp compact(%{"entity_id" => id, "state" => state, "attributes" => attrs}) do
    %{
      entity_id: id,
      name: attrs["friendly_name"] || id,
      state: state,
      media_title: attrs["media_title"],
      media_artist: attrs["media_artist"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  @doc """
  Which MA player to target. `name` present → the best fuzzy match (reuses
  `Entities.match_name/2`) or `{:error, :none}` if nothing matches. `name` nil → the sole
  player when there's exactly one (unambiguous); with more than one, `{:error, :ambiguous}` —
  the tool asks "which room?" rather than guessing.
  """
  def resolve_player(players, name) when is_binary(name) do
    case Entities.match_name(players, name) do
      [] -> {:error, :none}
      [best | _] -> {:ok, best}
    end
  end

  def resolve_player([player], _name), do: {:ok, player}
  def resolve_player([], _name), do: {:error, :none}
  def resolve_player(_players, _name), do: {:error, :ambiguous}

  @doc """
  Build the `music_assistant.play_media` service data (the caller merges `entity_id`):
  `media_id` = query, `enqueue` defaults to `"replace"`, `media_type` omitted entirely when
  nil/blank (let Music Assistant guess).
  """
  def play_media_data(query, media_type, enqueue) do
    %{media_id: query, enqueue: enqueue || "replace"}
    |> maybe_put_media_type(media_type)
  end

  defp maybe_put_media_type(data, nil), do: data
  defp maybe_put_media_type(data, ""), do: data
  defp maybe_put_media_type(data, type) when is_binary(type), do: Map.put(data, :media_type, type)
end
