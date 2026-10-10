defmodule App.Messages.Recipient do
  @moduledoc """
  Pure resolution of a household message's recipient from the brain's `to` arg.

  Deliberately NOT `App.Reminders.Target` / `App.Lists.Target`: those match a full display name
  only, fall back SILENTLY to the session user on a miss, and are gated on
  `household_named_targets`. A message must do the opposite on all three — "tell Tanya" has to
  work from a first name, a miss must be an error the brain can say out loud (never a message to
  yourself), and it is not gated: a message is a communication, not a write into someone's data.

  A user answers to: their display name, its first word, their email's local part, and — via
  their `:allowed_users` entry — the entry's own name (+ first word) and every alias email's
  local part. Case-insensitive; surrounding punctuation and doubled spaces are forgiven.
  """

  @self_words ["me", "myself", "self"]

  @doc """
  `{:ok, user}` for the OTHER allowlisted user `to` names; `{:error, :self}` when it names the
  sender; else `{:error, {:unknown_recipient, first_names_of_everyone_else}}`. `users` are the
  allowlisted user rows (`%{id, name, email}`), `allowlist` the `:allowed_users` entries.
  """
  def resolve(to, sender_id, users, allowlist) do
    wanted = normalize(to)
    {me, others} = Enum.split_with(users, &(&1.id == sender_id))

    cond do
      wanted == "" ->
        unknown(others)

      match = Enum.find(others, &(wanted in keys(&1, allowlist))) ->
        {:ok, match}

      wanted in @self_words or Enum.any?(me, &(wanted in keys(&1, allowlist))) ->
        {:error, :self}

      true ->
        unknown(others)
    end
  end

  @doc "How Henry says a user's name: the first word of their name, else their email's local part."
  def first_name(%{name: name, email: email}) do
    case name |> to_string() |> String.split() do
      [first | _] -> first
      [] -> email |> local_part() |> String.capitalize()
    end
  end

  defp unknown(others), do: {:error, {:unknown_recipient, Enum.map(others, &first_name/1)}}

  defp keys(user, allowlist) do
    entry = Enum.find(allowlist, &(user_email(user) in entry_emails(&1)))
    entry_name = entry && Map.get(entry, :name)
    emails = [user_email(user) | if(entry, do: entry_emails(entry), else: [])]

    [user.name, entry_name]
    |> Enum.flat_map(&name_keys/1)
    |> Enum.concat(Enum.map(emails, &local_part/1))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp name_keys(nil), do: []

  defp name_keys(name) do
    full = normalize(name)

    case String.split(full) do
      [first | _] -> [full, first]
      [] -> []
    end
  end

  defp entry_emails(entry),
    do: [entry.email | Map.get(entry, :aliases, [])] |> Enum.map(&String.downcase/1)

  defp user_email(user), do: user.email |> to_string() |> String.downcase()

  defp local_part(email),
    do: email |> to_string() |> String.downcase() |> String.split("@") |> hd()

  # Downcase, collapse whitespace, strip surrounding punctuation ("Tanya." / "@tanya" / "'Tanya'").
  defp normalize(s) when is_binary(s) do
    s
    |> String.downcase()
    |> String.split()
    |> Enum.join(" ")
    |> String.replace(~r/^[[:punct:]\s]+|[[:punct:]\s]+$/u, "")
  end

  defp normalize(_), do: ""
end
