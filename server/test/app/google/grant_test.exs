defmodule App.Google.GrantTest do
  # async: false — SQLite is single-writer and this inserts accounts.
  use App.DataCase, async: false

  alias App.Google.{Account, Grant}
  alias App.Repo
  alias App.Users.User

  @cal_read "https://www.googleapis.com/auth/calendar.readonly"
  @cal_write "https://www.googleapis.com/auth/calendar.events"
  @gmail_read "https://www.googleapis.com/auth/gmail.readonly"

  # google_accounts.user_id is a foreign key to users (migration
  # 20260625000003_scope_connections_to_user.exs), so each fixture needs a real
  # backing user rather than a bare literal id.
  defp account!(scopes) do
    {:ok, user} =
      %User{}
      |> User.changeset(%{email: "u-#{System.unique_integer([:positive])}@x.com", name: "U"})
      |> Repo.insert()

    {:ok, a} =
      %Account{}
      |> Account.changeset(%{
        user_id: user.id,
        email: "a@x.com",
        refresh_token: "rt",
        scope: Enum.join(["openid", "email" | scopes], " ")
      })
      |> Repo.insert()

    a
  end

  defp query(path) do
    [_, q] = String.split(path, "?", parts: 2)
    URI.decode_query(q)
  end

  test "a new account requests exactly the chosen connector at the chosen level" do
    assert query(Grant.path(:new, :gmail, :read)) == %{"gmail" => "read"}
  end

  test "a new account at :none is a no-op" do
    assert Grant.path(:new, :gmail, :none) == nil
  end

  test "changing one connector PRESERVES the account's other connectors at their own levels" do
    # The two connectors are at DIFFERENT levels on purpose: an implementation that
    # preserved the others but flattened them to one level would pass a same-level
    # fixture. Gmail is being raised to :write; calendar must survive at :read.
    account = account!([@cal_read, @gmail_read])

    assert query(Grant.path(account, :gmail, :write)) ==
             %{"calendar" => "read", "gmail" => "write", "account" => to_string(account.id)}
  end

  test "reducing a connector to :none drops it and keeps the rest" do
    account = account!([@cal_write, @gmail_read])

    assert query(Grant.path(account, :gmail, :none)) ==
             %{"calendar" => "write", "account" => to_string(account.id)}
  end

  test "reducing the account's ONLY connector leaves just the account id" do
    # The controller reads empty grants + an account param as "remove all"
    # (google_auth_controller.ex, grants_from_params/1) — so this path must still
    # carry the account, or the request silently becomes a bare connect.
    account = account!([@gmail_read])
    assert query(Grant.path(account, :gmail, :none)) == %{"account" => to_string(account.id)}
  end
end
