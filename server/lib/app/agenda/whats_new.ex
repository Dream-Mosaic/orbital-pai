defmodule App.Agenda.WhatsNew do
  @moduledoc """
  Once per user per release, Henry mentions what he learned — after the user's first exchange
  (`:after_next_turn`, so it never opens a conversation or talks to an empty room), spoken
  verbatim (`canned`), short enough to hear in one breath. Pulled on connect like the briefing;
  the claim (`users.whats_new_seen = @release`) happens at delivery via the item's `ack`, so a
  dropped connection before it's spoken just means it's offered again next time.

  To announce a new release: bump `@release` and rewrite `notes/1`. Keep it to the few things
  someone would actually try, each with words they could say.
  """
  alias App.Agenda.Item
  alias App.Users
  alias App.Users.User

  @release "2026-10-10"

  def release, do: @release

  @doc "The what's-new item for the session's user, or nil (already heard it / no user)."
  def pull(session_id) do
    with true <- Application.get_env(:app, :whats_new, true),
         id when is_integer(id) <- Users.id_from_session(session_id),
         %User{} = user <- Users.get(id),
         true <- user.whats_new_seen != @release do
      item(user)
    else
      _ -> nil
    end
  end

  @doc false
  def item(%User{} = user) do
    %Item{
      kind: :news,
      canned: true,
      deliver: :after_next_turn,
      lead_idle: "Oh — quick one —",
      lead_interjected: "Oh — before you go —",
      prompt: notes(other_name(user)),
      persist_as: "(what's new in Henry)",
      ack: {__MODULE__, :mark_seen, [user.id]}
    }
  end

  @doc false
  def notes(other) do
    tell =
      if other,
        do: "pass messages to #{other} — just say \"tell #{other}…\"",
        else: "pass messages around the house"

    "I picked up a few new tricks today. I can run kitchen timers — \"set a pasta timer for " <>
      "ten minutes\" — #{tell}, and walk you through a recipe one step at a time. You can " <>
      "also type to me with the little speech-bubble key when you can't talk out loud."
  end

  @doc "Stamp the release as heard (the item's ack)."
  def mark_seen(user_id) do
    case Users.get(user_id) do
      %User{} = user ->
        Users.with_busy_retry(fn ->
          user |> Ecto.Changeset.change(whats_new_seen: @release) |> App.Repo.update!()
        end)

      nil ->
        :ok
    end
  end

  defp other_name(%User{id: id}) do
    Users.list()
    |> Enum.find(&(&1.id != id and Users.allowed?(&1.email)))
    |> case do
      %User{name: name} when is_binary(name) and name != "" -> name |> String.split() |> hd()
      _ -> nil
    end
  end
end
