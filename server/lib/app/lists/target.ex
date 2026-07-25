defmodule App.Lists.Target do
  @moduledoc """
  Pure resolution of a list's owner from the brain's `for` arg. A mirror of
  `App.Reminders.Target` with the default FLIPPED TO HOUSEHOLD: unspecified/household-words
  always resolve to the shared household list (unconditional — "shared by default" is the
  headline decision, unlike reminders' personal default). Personal words resolve to the session
  user. A NAMED person is gated by `kiosk_user_switch` (like reminders' user-switching) since
  attributing something to someone else by voice needs the trusted-wall context; gate off (or an
  unrecognized name) falls back to the session user, personal — never silently household to a
  stranger. Returns `%{user_id, household, assigned}` — `assigned` is a human label the brain
  reads back so it never silently mis-scopes.
  """

  @household_label "the household"
  @self_label "you"

  @spec resolve(String.t() | nil, map()) :: %{
          user_id: integer(),
          household: boolean(),
          assigned: String.t()
        }
  def resolve(for_arg, %{session_user_id: sid, gate_on: gate, users: users}) do
    case normalize(for_arg) do
      :household -> household(sid)
      :self -> personal(sid, @self_label)
      {:name, name} -> if gate, do: by_name(name, users, sid), else: personal(sid, @self_label)
    end
  end

  # nil/""/household-words -> :household (SHARED BY DEFAULT, unconditional); personal words ->
  # :self ; anything else -> {:name, it}
  defp normalize(nil), do: :household

  defp normalize(s) when is_binary(s) do
    case String.downcase(String.trim(s)) do
      x when x in ["", "household", "us", "we", "both", "the house", "the household"] ->
        :household

      x when x in ["self", "my", "me", "mine", "myself", "personal"] ->
        :self

      name ->
        {:name, name}
    end
  end

  defp normalize(_), do: :household

  defp by_name(name, users, sid) do
    case Enum.find(users, fn u -> String.downcase(u.name || "") == name end) do
      nil -> personal(sid, @self_label)
      %{id: id, name: n} -> personal(id, n)
    end
  end

  defp household(sid), do: %{user_id: sid, household: true, assigned: @household_label}
  defp personal(id, label), do: %{user_id: id, household: false, assigned: label}
end
