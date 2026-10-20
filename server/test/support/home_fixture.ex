defmodule App.Test.HomeFixture do
  @moduledoc """
  The household's real (sanitized) Home Assistant snapshot as test input: registries, exposure
  and trimmed states in HA's own string-keyed shapes. `exposed` is already the inner
  `exposed_entities` map.
  """

  alias App.HomeAssistant.Directory

  @path Path.expand("../fixtures/home_assistant/directory_snapshot.json", __DIR__)
  @external_resource @path

  def payloads do
    snap = @path |> File.read!() |> Jason.decode!()

    %{
      areas: snap["areas"],
      devices: snap["devices"],
      entities: snap["entities"],
      states: snap["states"],
      exposed: snap["exposed"]
    }
  end

  def directory, do: Directory.build(payloads(), ~U[2026-10-19 20:00:00Z])

  @doc "The payloads with `alias` added to one registry entity's aliases."
  def with_alias(entity_id, alias_name) do
    p = payloads()

    entities =
      Enum.map(p.entities, fn
        %{"entity_id" => ^entity_id} = e ->
          %{e | "aliases" => (e["aliases"] || []) ++ [alias_name]}

        e ->
          e
      end)

    %{p | entities: entities}
  end
end
