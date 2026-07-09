defmodule App.Users do
  @moduledoc """
  The people who use the app. Sign-in is gated by an allowlist (`:allowed_users`, an ORDERED list of
  `%{email, name, aliases?}` — the first entry is the primary, who owns pre-existing connections).
  An entry's `:email` is the CANONICAL identity; optional `:aliases` are extra Google emails that
  log into the SAME instance (one user can sign in from several accounts/browsers). Emails are
  stored downcased, keyed by the canonical. `upsert_allowed/1` is the login path; `ensure_allowlisted/0`
  is the seed path.
  """
  import Ecto.Query
  alias App.Repo
  alias App.Users.User

  def allowlist, do: Application.get_env(:app, :allowed_users, [])

  # Every email that maps to this entry (canonical + aliases), downcased.
  defp entry_emails(entry) do
    [entry.email | Map.get(entry, :aliases, [])] |> Enum.map(&String.downcase/1)
  end

  # The allowlist entry a (canonical or alias) email belongs to, or nil.
  defp entry_for(email) when is_binary(email) do
    e = String.downcase(email)
    Enum.find(allowlist(), fn entry -> e in entry_emails(entry) end)
  end

  defp entry_for(_), do: nil

  def allowed?(email), do: entry_for(email) != nil

  def list, do: Repo.all(from u in User, order_by: [asc: u.id])
  def get(id), do: Repo.get(User, id)

  @doc "The user id encoded in a session key (`to_string(user.id)`), or nil if the string isn't one."
  def id_from_session(sid) when is_binary(sid) do
    case Integer.parse(sid) do
      {id, ""} -> id
      _ -> nil
    end
  end

  def id_from_session(_), do: nil

  def get_by_email(email) when is_binary(email),
    do: Repo.get_by(User, email: String.downcase(email))

  @doc """
  Upsert an allowlisted user from a verified email (canonical OR alias). The row is keyed by the
  entry's CANONICAL email, so all of a user's aliases resolve to the same instance.
  `{:error, :not_allowed}` if the email is in no entry.
  """
  def upsert_allowed(email) when is_binary(email) do
    case entry_for(email) do
      nil ->
        {:error, :not_allowed}

      entry ->
        canonical = String.downcase(entry.email)

        (get_by_email(canonical) || %User{})
        |> User.changeset(%{email: canonical, name: entry.name})
        |> Repo.insert_or_update()
    end
  end

  def upsert_allowed(_), do: {:error, :not_allowed}

  @doc "Ensure a row exists for every allowlisted email; returns the primary (first allowlisted)."
  def ensure_allowlisted do
    Enum.each(allowlist(), fn entry ->
      e = String.downcase(entry.email)

      unless get_by_email(e) do
        %User{} |> User.changeset(%{email: e, name: entry.name}) |> Repo.insert!()
      end
    end)

    primary()
  end

  @doc "Persist voice preference changes (default_abi, default_ptt) for a user."
  def update_prefs(%User{} = user, attrs) do
    user |> User.prefs_changeset(attrs) |> Repo.update()
  end

  @doc "The primary user (owner of pre-existing connections) = first allowlisted email."
  def primary do
    case allowlist() do
      [first | _] -> get_by_email(first.email)
      [] -> nil
    end
  end
end
