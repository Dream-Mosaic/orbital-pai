defmodule App.Google.ConnectorsTest do
  use ExUnit.Case, async: true

  alias App.Google.{Account, Connectors}

  @ro "https://www.googleapis.com/auth/calendar.readonly"
  @rw "https://www.googleapis.com/auth/calendar.events"

  @gmail_ro "https://www.googleapis.com/auth/gmail.readonly"
  @gmail_send "https://www.googleapis.com/auth/gmail.send"

  defp acct(scope), do: %Account{scope: scope}

  test "access resolves :write, :read, :none from the granted scope string" do
    assert Connectors.access(acct("#{@rw} openid email"), :calendar) == :write
    assert Connectors.access(acct("#{@ro} openid email"), :calendar) == :read
    assert Connectors.access(acct("openid email"), :calendar) == :none
    assert Connectors.access(acct(nil), :calendar) == :none
  end

  test "write implies read; can_read?/can_write? follow access" do
    w = acct("#{@rw} openid email")
    r = acct("#{@ro} openid email")
    n = acct("openid email")

    assert Connectors.can_read?(w, :calendar)
    assert Connectors.can_write?(w, :calendar)
    assert Connectors.can_read?(r, :calendar)
    refute Connectors.can_write?(r, :calendar)
    refute Connectors.can_read?(n, :calendar)
    refute Connectors.can_write?(n, :calendar)
  end

  test "scopes_for builds requested scopes; write is a superset of read; always openid+email" do
    read = Connectors.scopes_for(%{calendar: :read})
    write = Connectors.scopes_for(%{calendar: :write})

    assert "openid" in read and "email" in read
    assert @ro in read
    refute @rw in read

    assert @ro in write and @rw in write
    assert Enum.all?(read, &(&1 in write))
  end

  test "scopes_for ignores :none and dedupes" do
    assert Connectors.scopes_for(%{calendar: :none}) == ["openid", "email"]
  end

  test "reduction? is true only when a currently-granted connector scope is dropped" do
    full = "#{@rw} openid email"

    assert Connectors.reduction?(full, Connectors.scopes_for(%{calendar: :read}))
    refute Connectors.reduction?(full, Connectors.scopes_for(%{calendar: :write}))

    refute Connectors.reduction?(
             "#{@ro} openid email",
             Connectors.scopes_for(%{calendar: :write})
           )
  end

  test "reduction? treats a nil current scope as nothing granted" do
    refute Connectors.reduction?(nil, Connectors.scopes_for(%{calendar: :write}))
  end

  test "label and all expose the registry" do
    assert Connectors.label(:calendar) == "Google Calendar"
    assert :calendar in Connectors.all()
  end

  test "access_levels lists the selectable levels for a connector" do
    assert Connectors.access_levels(:calendar) == [:none, :read, :write]
  end

  test "gmail access resolves from the granted scope string" do
    assert Connectors.access(acct("#{@gmail_send} #{@gmail_ro} openid email"), :gmail) == :write
    assert Connectors.access(acct("#{@gmail_ro} openid email"), :gmail) == :read
    assert Connectors.access(acct("openid email"), :gmail) == :none
  end

  test "gmail scopes_for(:write) requests readonly + send; read is a subset" do
    read = Connectors.scopes_for(%{gmail: :read})
    write = Connectors.scopes_for(%{gmail: :write})

    assert @gmail_ro in read
    refute @gmail_send in read

    assert @gmail_ro in write and @gmail_send in write
    assert Enum.all?(read, &(&1 in write))
  end

  test "reduction? fires on a gmail write -> read downgrade" do
    full = "#{@gmail_send} #{@gmail_ro} openid email"
    assert Connectors.reduction?(full, Connectors.scopes_for(%{gmail: :read}))
    refute Connectors.reduction?(full, Connectors.scopes_for(%{gmail: :write}))
  end

  test "gmail is in the registry with a label" do
    assert Connectors.label(:gmail) == "Gmail"
    assert :gmail in Connectors.all()
  end
end
