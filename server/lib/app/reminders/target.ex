defmodule App.Reminders.Target do
  @moduledoc """
  Pure resolution of a reminder's owner from the brain's `for` arg + the session's active scope +
  the master gate. Returns `%{user_id, household, assigned}` — `assigned` is a human label the brain
  reads back so it never silently mis-assigns (see the spec's Fable I6). Injected `opts` keep it pure.
  """

  @household_label "the household"
  @self_label "you"

  @spec resolve(String.t() | nil, map()) :: %{
          user_id: integer(),
          household: boolean(),
          assigned: String.t()
        }
  def resolve(for_arg, %{session_user_id: sid, active_scope: scope, gate_on: gate, users: users}) do
    case normalize(for_arg) do
      :self ->
        if gate and scope == :household, do: household(sid), else: personal(sid, @self_label)

      :household ->
        if gate, do: household(sid), else: personal(sid, @self_label)

      {:name, name} ->
        by_name(name, users, sid)
    end
  end

  # "self"/"me"/nil/"" -> :self ; household words -> :household ; anything else -> {:name, it}
  defp normalize(nil), do: :self

  defp normalize(s) when is_binary(s) do
    case String.downcase(String.trim(s)) do
      x when x in ["", "self", "me", "myself"] -> :self
      x when x in ["household", "us", "we", "both", "the house", "the household"] -> :household
      name -> {:name, name}
    end
  end

  defp normalize(_), do: :self

  defp by_name(name, users, sid) do
    case Enum.find(users, fn u -> String.downcase(u.name || "") == name end) do
      nil -> personal(sid, @self_label)
      %{id: id, name: n} -> personal(id, n)
    end
  end

  defp household(sid), do: %{user_id: sid, household: true, assigned: @household_label}
  defp personal(id, label), do: %{user_id: id, household: false, assigned: label}
end
