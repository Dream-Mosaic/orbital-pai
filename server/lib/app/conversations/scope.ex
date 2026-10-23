defmodule App.Conversations.Scope do
  @moduledoc """
  Whose turn this is: `:personal` (the signed-in user's own) or `:household` (spec
  2026-10-23-wall-tablet-design, phase 4 — a shared household device).

  The scope follows the **bound** device, never "any joined device": the Conversation is one
  per user, so a wall in shared mode must not leak household scope onto the same user's phone
  (review finding C1, July). The Conversation publishes the bound device's scope as its value
  in `App.Conversations.Registry` (only the owner may write it, so every write happens inside
  the Conversation process), and anything holding a session id reads it here — the reminder,
  list and garden tools, `App.Tools.execute/3` and `Gemini.stream_brain/4` — so every brain
  path agrees without threading a new argument through each.

  One ETS read, safe from any process (tool tasks, the brain task). No session, no live
  conversation, or a value that isn't `:household` all read as `:personal`.
  """

  @registry App.Conversations.Registry

  @type t :: :personal | :household

  @spec current(String.t() | nil) :: t()
  def current(session_id) when is_binary(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{_pid, :household}] -> :household
      _ -> :personal
    end
  end

  def current(_session_id), do: :personal

  @doc """
  Publish `scope` as the CALLING process's value under `session_id`. Only the registered owner
  (the session's Conversation) can write it; from anywhere else, or for a process that isn't
  registered (a bare Conversation in a unit test), this is a harmless no-op.
  """
  @spec publish(String.t() | nil, t()) :: :ok
  def publish(session_id, scope) when is_binary(session_id) do
    Registry.update_value(@registry, session_id, fn _ -> scope end)
    :ok
  end

  def publish(_session_id, _scope), do: :ok
end
