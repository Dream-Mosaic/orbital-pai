defmodule App.Reminders.Delivery do
  @moduledoc """
  Pure resolution of WHICH user's session should speak a fired household reminder: the wall (a
  Presence entry flagged `kiosk: true`) first, else any active member, else nobody. Deterministic
  (kiosk-first, then lowest user_id) so behavior + tests are stable. Operates on a Presence snapshot
  (`AppWeb.Presence.list("presence:voice")`) so it needs no live process.
  """

  @spec target(map()) :: integer() | nil
  def target(presence_map) when is_map(presence_map) do
    entries =
      presence_map
      |> Enum.map(fn {uid, %{metas: metas}} -> {to_int(uid), Enum.any?(metas, & &1[:kiosk])} end)
      |> Enum.reject(fn {uid, _kiosk} -> is_nil(uid) end)

    kiosk = entries |> Enum.filter(fn {_uid, k} -> k end) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    any = entries |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    List.first(kiosk) || List.first(any)
  end

  defp to_int(uid) when is_integer(uid), do: uid

  defp to_int(uid) when is_binary(uid) do
    case Integer.parse(uid) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_int(_), do: nil
end
