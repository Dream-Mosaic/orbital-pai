defmodule App.Google.Accounts do
  @moduledoc """
  Connected Google accounts: CRUD plus the access-token lifecycle. `valid_access_token/1`
  returns a live token, refreshing + persisting when the stored one is expired. Tokens are
  stored plaintext in the local SQLite file (single-user, local app — same trust level as the
  `.env` keys).
  """
  import Ecto.Query
  require Logger
  alias App.Repo
  alias App.Google.{Account, Connectors, OAuth}

  def list(user_id),
    do: Repo.all(from a in Account, where: a.user_id == ^user_id, order_by: [asc: a.id])

  @doc "The given user's connected accounts that can READ the given connector."
  def accounts_with_read(user_id, conn),
    do: Enum.filter(list(user_id), &Connectors.can_read?(&1, conn))

  @doc "The given user's connected accounts that can WRITE the given connector."
  def accounts_with_write(user_id, conn),
    do: Enum.filter(list(user_id), &Connectors.can_write?(&1, conn))

  def get_by_email(email), do: Repo.get_by(Account, email: email)

  @doc "The given user's default account for writes (or nil if none)."
  def default(user_id),
    do:
      Repo.one(from a in Account, where: a.user_id == ^user_id and a.is_default == true, limit: 1)

  @doc "Make `account` the sole default for ITS user (clears the flag on that user's others)."
  def set_default(%Account{user_id: uid} = account) do
    Repo.transaction(fn ->
      Repo.update_all(from(a in Account, where: a.user_id == ^uid), set: [is_default: false])
      {:ok, updated} = account |> Account.changeset(%{is_default: true}) |> Repo.update()
      updated
    end)
  end

  @doc """
  Insert or update (keyed by email) from an OAuth exchange result
  `%{access_token, refresh_token, expires_in, id_token}`, owned by `user_id`. The email is
  decoded from the id_token; the label defaults to the email.
  """
  def upsert_from_oauth(oauth, user_id) do
    case OAuth.email_from_id_token(oauth.id_token) do
      nil ->
        {:error, :no_email}

      email ->
        # Emails are globally unique here, so re-connecting an email already owned by another user
        # TRANSFERS ownership. Fine for the 2-known-user rollout; revisit (reject/fork) if it grows.
        account = get_by_email(email) || %Account{}

        first? =
          is_nil(account.id) and
            Repo.aggregate(from(a in Account, where: a.user_id == ^user_id), :count) == 0

        # re-connecting an email already owned by a DIFFERENT user transfers the row; a stale
        # `is_default: true` from the prior owner must not carry over.
        transfer? = not is_nil(account.id) and account.user_id != user_id

        attrs = %{
          user_id: user_id,
          email: email,
          refresh_token: oauth.refresh_token,
          access_token: oauth.access_token,
          access_token_expires_at: expires_at(oauth.expires_in),
          scope: oauth[:scope] || account.scope
        }

        # label defaults to the email on first connect; preserved on reconnect.
        attrs = if is_nil(account.id), do: Map.put(attrs, :label, email), else: attrs

        # the first account ever connected becomes the write default; a transferred row drops the
        # prior owner's default. Otherwise leave is_default untouched.
        attrs =
          cond do
            first? -> Map.put(attrs, :is_default, true)
            transfer? -> Map.put(attrs, :is_default, false)
            true -> attrs
          end

        account
        |> Account.changeset(attrs)
        |> Repo.insert_or_update()
    end
  end

  @doc """
  A live access token for the account. Refreshes + persists when the stored token is within
  60s of expiry. Returns `{:ok, token}` | `{:error, :needs_reconnect}` | `{:error, reason}`.
  """
  def valid_access_token(%Account{} = account) do
    if fresh?(account), do: {:ok, account.access_token}, else: do_refresh(account)
  end

  def delete(%Account{} = account), do: Repo.delete(account)

  defp do_refresh(account) do
    case OAuth.refresh(account.refresh_token) do
      {:ok, %{access_token: at, expires_in: exp}} ->
        # best-effort cache; the token is valid this turn even if the write fails, and a
        # failed write just means the next call refreshes again — never crash the caller.
        # But DO log a failed write: under the concurrent multi-account fan-out SQLite's
        # single writer can lose the race, which leaves the token stale and re-refreshing
        # every call (a real "this account keeps erroring" smell).
        case account
             |> Account.changeset(%{access_token: at, access_token_expires_at: expires_at(exp)})
             |> Repo.update() do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[google] token persist failed for #{account.email}: #{inspect(reason)} " <>
                "(token valid this turn; will re-refresh next call)"
            )
        end

        {:ok, at}

      {:error, :invalid_grant} ->
        Logger.warning("[google] refresh failed for #{account.email}: invalid_grant — reconnect")
        {:error, :needs_reconnect}

      {:error, reason} ->
        Logger.warning("[google] refresh failed for #{account.email}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fresh?(%Account{access_token: nil}), do: false
  defp fresh?(%Account{access_token_expires_at: nil}), do: false

  defp fresh?(%Account{access_token_expires_at: exp}) do
    DateTime.compare(exp, DateTime.add(now(), 60, :second)) == :gt
  end

  defp expires_at(expires_in) when is_integer(expires_in) do
    now() |> DateTime.add(expires_in, :second) |> DateTime.truncate(:second)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
