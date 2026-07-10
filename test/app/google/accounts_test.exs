defmodule App.Google.AccountsTest do
  use App.DataCase, async: false

  alias App.Google.{Account, Accounts}
  alias App.Repo
  alias App.Users.User

  setup do
    {:ok, user} =
      %User{} |> User.changeset(%{email: "alice@x.com", name: "Alice"}) |> Repo.insert()

    %{user: user}
  end

  defp user_id(%{user: user}), do: user.id

  # An id_token whose payload carries the given email (matches OAuth.email_from_id_token).
  defp id_token(email) do
    "h." <> Base.url_encode64(Jason.encode!(%{"email" => email}), padding: false) <> ".sig"
  end

  defp oauth(email, opts \\ []) do
    %{
      access_token: Keyword.get(opts, :access_token, "at-1"),
      refresh_token: Keyword.get(opts, :refresh_token, "rt-1"),
      expires_in: Keyword.get(opts, :expires_in, 3599),
      id_token: id_token(email),
      scope:
        Keyword.get(
          opts,
          :scope,
          "https://www.googleapis.com/auth/calendar.events openid email"
        )
    }
  end

  test "upsert_from_oauth inserts a new account, label defaults to email", ctx do
    uid = user_id(ctx)

    assert {:ok, acc} = Accounts.upsert_from_oauth(oauth("alice@example.com"), uid)
    assert acc.user_id == uid
    assert acc.email == "alice@example.com"
    assert acc.label == "alice@example.com"
    assert acc.refresh_token == "rt-1"
    assert acc.scope =~ "calendar.events"
    assert [_one] = Accounts.list(uid)
  end

  test "upsert_from_oauth updates tokens for an existing email (reconnect)", ctx do
    uid = user_id(ctx)
    {:ok, _} = Accounts.upsert_from_oauth(oauth("a@x.com", refresh_token: "old"), uid)
    {:ok, acc} = Accounts.upsert_from_oauth(oauth("a@x.com", refresh_token: "new"), uid)

    assert acc.refresh_token == "new"
    assert [_one] = Accounts.list(uid)
  end

  test "upsert_from_oauth preserves a custom label on reconnect", ctx do
    uid = user_id(ctx)
    {:ok, acc} = Accounts.upsert_from_oauth(oauth("a@x.com"), uid)

    {:ok, _} =
      acc |> Account.changeset(%{label: "personal"}) |> Repo.update()

    {:ok, _} = Accounts.upsert_from_oauth(oauth("a@x.com", refresh_token: "new"), uid)

    assert Accounts.get_by_email("a@x.com").label == "personal"
  end

  test "upsert_from_oauth without a decodable email errors", ctx do
    bad = %{access_token: "at", refresh_token: "rt", expires_in: 3599, id_token: "garbage"}
    assert {:error, :no_email} = Accounts.upsert_from_oauth(bad, user_id(ctx))
  end

  test "valid_access_token returns the cached token when still fresh", ctx do
    {:ok, acc} = Accounts.upsert_from_oauth(oauth("a@x.com", access_token: "fresh"), user_id(ctx))
    assert {:ok, "fresh"} = Accounts.valid_access_token(acc)
  end

  test "valid_access_token refreshes and persists when expired", ctx do
    Application.put_env(:app, :google_req_opts, plug: {Req.Test, AccRefreshStub})
    on_exit(fn -> Application.delete_env(:app, :google_req_opts) end)
    System.put_env("GOOGLE_CLIENT_ID", "id")
    System.put_env("GOOGLE_CLIENT_SECRET", "secret")

    on_exit(fn ->
      System.delete_env("GOOGLE_CLIENT_ID")
      System.delete_env("GOOGLE_CLIENT_SECRET")
    end)

    Req.Test.stub(AccRefreshStub, fn conn ->
      Req.Test.json(conn, %{"access_token" => "refreshed", "expires_in" => 3599})
    end)

    {:ok, acc} = Accounts.upsert_from_oauth(oauth("a@x.com", access_token: "stale"), user_id(ctx))
    # force expiry
    {:ok, acc} =
      acc
      |> Account.changeset(%{access_token_expires_at: ~U[2000-01-01 00:00:00Z]})
      |> Repo.update()

    assert {:ok, "refreshed"} = Accounts.valid_access_token(acc)
    assert Accounts.get_by_email("a@x.com").access_token == "refreshed"
  end

  test "valid_access_token refreshes when access_token_expires_at is nil", ctx do
    Application.put_env(:app, :google_req_opts, plug: {Req.Test, AccNilExpiryStub})
    on_exit(fn -> Application.delete_env(:app, :google_req_opts) end)
    System.put_env("GOOGLE_CLIENT_ID", "id")
    System.put_env("GOOGLE_CLIENT_SECRET", "secret")

    on_exit(fn ->
      System.delete_env("GOOGLE_CLIENT_ID")
      System.delete_env("GOOGLE_CLIENT_SECRET")
    end)

    Req.Test.stub(AccNilExpiryStub, fn conn ->
      Req.Test.json(conn, %{"access_token" => "refreshed", "expires_in" => 3599})
    end)

    {:ok, acc} = Accounts.upsert_from_oauth(oauth("a@x.com", access_token: "stale"), user_id(ctx))

    {:ok, acc} =
      acc |> Account.changeset(%{access_token_expires_at: nil}) |> Repo.update()

    assert {:ok, "refreshed"} = Accounts.valid_access_token(acc)
  end

  test "valid_access_token maps invalid_grant to needs_reconnect", ctx do
    Application.put_env(:app, :google_req_opts, plug: {Req.Test, AccBadStub})
    on_exit(fn -> Application.delete_env(:app, :google_req_opts) end)
    System.put_env("GOOGLE_CLIENT_ID", "id")
    System.put_env("GOOGLE_CLIENT_SECRET", "secret")

    on_exit(fn ->
      System.delete_env("GOOGLE_CLIENT_ID")
      System.delete_env("GOOGLE_CLIENT_SECRET")
    end)

    Req.Test.stub(AccBadStub, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})
    end)

    {:ok, acc} = Accounts.upsert_from_oauth(oauth("a@x.com"), user_id(ctx))

    {:ok, acc} =
      acc
      |> Account.changeset(%{access_token_expires_at: ~U[2000-01-01 00:00:00Z]})
      |> Repo.update()

    assert {:error, :needs_reconnect} = Accounts.valid_access_token(acc)
  end

  test "delete removes the account", ctx do
    uid = user_id(ctx)
    {:ok, acc} = Accounts.upsert_from_oauth(oauth("a@x.com"), uid)
    assert {:ok, _} = Accounts.delete(acc)
    assert Accounts.list(uid) == []
  end

  test "deleting an account purges its semantic footprint (vectors + source_items)" do
    App.Test.Fakes.VectorStore.reset()
    Application.put_env(:app, :allowed_users, [%{email: "pz@x.com", name: "Pz"}])
    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, u} = App.Users.upsert_allowed("pz@x.com")

    {:ok, acc} =
      %App.Google.Account{}
      |> App.Google.Account.changeset(%{
        user_id: u.id,
        email: "pz@x.com",
        label: "A",
        refresh_token: "rt",
        access_token: "at",
        access_token_expires_at:
          DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)
      })
      |> App.Repo.insert()

    :ok =
      App.Test.Fakes.VectorStore.upsert([
        %{
          id: "email:m1",
          vector: [0.0],
          payload: %{user_id: u.id, source: "email", external_id: "m1", account_id: acc.id}
        }
      ])

    {:ok, _} =
      App.Sources.Items.record(%{
        user_id: u.id,
        account_id: acc.id,
        source: "email",
        external_id: "m1",
        content_hash: "m1",
        indexed_at: DateTime.utc_now()
      })

    App.Google.Accounts.delete(acc)

    assert App.Sources.Items.refs_indexed(u.id, "email", acc.id) == %{}
    {:ok, hits} = App.Test.Fakes.VectorStore.search([0.0], u.id, 10)
    assert hits == []
  end

  test "the first connected account becomes the default; later ones do not", ctx do
    uid = user_id(ctx)
    {:ok, a} = Accounts.upsert_from_oauth(oauth("a@x.com"), uid)
    {:ok, b} = Accounts.upsert_from_oauth(oauth("b@x.com"), uid)

    assert a.is_default == true
    assert b.is_default == false
    assert Accounts.default(uid).email == "a@x.com"
  end

  test "re-connecting an email owned by another user transfers it and clears is_default", ctx do
    a = user_id(ctx)

    {:ok, b_user} =
      %User{} |> User.changeset(%{email: "b@x.com", name: "Bee"}) |> Repo.insert()

    # A connects shared@x.com as their (first → default) account
    {:ok, acct} = Accounts.upsert_from_oauth(oauth("shared@x.com"), a)
    assert acct.is_default

    # B re-connects the same email → transfers to B, default reset
    {:ok, moved} = Accounts.upsert_from_oauth(oauth("shared@x.com"), b_user.id)
    assert moved.user_id == b_user.id
    refute moved.is_default
    assert Accounts.list(a) == []
    assert Enum.map(Accounts.list(b_user.id), & &1.email) == ["shared@x.com"]
  end

  test "reconnecting an account preserves the default flag", ctx do
    uid = user_id(ctx)
    {:ok, _} = Accounts.upsert_from_oauth(oauth("a@x.com"), uid)
    {:ok, a2} = Accounts.upsert_from_oauth(oauth("a@x.com", refresh_token: "new"), uid)
    assert a2.is_default == true
  end

  test "set_default makes exactly one account default", ctx do
    uid = user_id(ctx)
    {:ok, _a} = Accounts.upsert_from_oauth(oauth("a@x.com"), uid)
    {:ok, b} = Accounts.upsert_from_oauth(oauth("b@x.com"), uid)

    {:ok, _} = Accounts.set_default(b)

    assert Accounts.default(uid).email == "b@x.com"
    assert Enum.count(Accounts.list(uid), & &1.is_default) == 1
  end

  test "default returns nil when no accounts exist", ctx do
    assert Accounts.default(user_id(ctx)) == nil
  end

  test "upsert_from_oauth persists the GRANTED scope from the oauth result", ctx do
    {:ok, acc} =
      Accounts.upsert_from_oauth(
        oauth("g@x.com", scope: "https://www.googleapis.com/auth/calendar.readonly openid email"),
        user_id(ctx)
      )

    assert acc.scope == "https://www.googleapis.com/auth/calendar.readonly openid email"
  end

  test "accounts_with_read / accounts_with_write filter by connector access", ctx do
    uid = user_id(ctx)
    {:ok, _w} = Accounts.upsert_from_oauth(oauth("w@x.com"), uid)

    {:ok, _r} =
      Accounts.upsert_from_oauth(
        oauth("r@x.com", scope: "https://www.googleapis.com/auth/calendar.readonly openid email"),
        uid
      )

    read = Enum.map(Accounts.accounts_with_read(uid, :calendar), & &1.email) |> Enum.sort()
    write = Enum.map(Accounts.accounts_with_write(uid, :calendar), & &1.email)

    assert read == ["r@x.com", "w@x.com"]
    assert write == ["w@x.com"]
  end

  test "accounts are isolated per user: list/default/reads return only that user's", ctx do
    alice = user_id(ctx)

    {:ok, bob} =
      %User{} |> User.changeset(%{email: "bob@x.com", name: "Bob"}) |> Repo.insert()

    {:ok, d} = Accounts.upsert_from_oauth(oauth("alice-acct@x.com"), alice)
    {:ok, t} = Accounts.upsert_from_oauth(oauth("bob-acct@x.com"), bob.id)

    # each user's first account is their OWN default
    assert d.is_default == true
    assert t.is_default == true

    assert Enum.map(Accounts.list(alice), & &1.email) == ["alice-acct@x.com"]
    assert Enum.map(Accounts.list(bob.id), & &1.email) == ["bob-acct@x.com"]

    assert Accounts.default(alice).email == "alice-acct@x.com"
    assert Accounts.default(bob.id).email == "bob-acct@x.com"

    assert Enum.map(Accounts.accounts_with_read(alice, :calendar), & &1.email) ==
             ["alice-acct@x.com"]

    # connect a SECOND account for alice and make it default — must not touch bob's default
    {:ok, d2} = Accounts.upsert_from_oauth(oauth("alice-2@x.com"), alice)
    {:ok, _} = Accounts.set_default(d2)

    assert Accounts.default(alice).email == "alice-2@x.com"
    assert Accounts.default(bob.id).email == "bob-acct@x.com"
    assert Repo.reload(t).is_default == true
  end
end
