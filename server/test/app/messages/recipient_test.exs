defmodule App.Messages.RecipientTest do
  use ExUnit.Case, async: true

  alias App.Messages.Recipient

  @david %{id: 1, name: "David Clausen", email: "dave@x.com"}
  @tanya %{id: 2, name: "Tanya Clausen", email: "tanya.c@x.com"}
  @users [@david, @tanya]
  @allowlist [
    %{email: "dave@x.com", name: "David"},
    %{email: "tanya.c@x.com", name: "Tanya", aliases: ["TeeDee@y.com"]}
  ]

  defp resolve(to, sender \\ @david), do: Recipient.resolve(to, sender.id, @users, @allowlist)

  test "first name, full name — case-insensitive, punctuation and spacing forgiven" do
    for to <- ["Tanya", "tanya", "TANYA", " Tanya. ", "tanya clausen", "Tanya  Clausen"] do
      assert {:ok, %{id: 2}} = resolve(to), "expected #{inspect(to)} to resolve to Tanya"
    end
  end

  test "email local part and an allowlist alias's local part both resolve" do
    assert {:ok, %{id: 2}} = resolve("tanya.c")
    assert {:ok, %{id: 2}} = resolve("teedee")
  end

  test "the allowlist entry's own name counts, even when the row's name differs (OIDC name)" do
    users = [@david, %{@tanya | name: "T. Clausen"}]
    assert {:ok, %{id: 2}} = Recipient.resolve("Tanya", 1, users, @allowlist)
  end

  test "naming yourself is :self, never a silent message to someone else" do
    assert {:error, :self} = resolve("David")
    assert {:error, :self} = resolve("dave")
    assert {:error, :self} = resolve("me")
    assert {:error, :self} = resolve("Tanya", @tanya)
  end

  test "an unknown name lists the people you CAN message (first names, not you)" do
    assert {:error, {:unknown_recipient, ["Tanya"]}} = resolve("Bob")
    assert {:error, {:unknown_recipient, ["David"]}} = resolve("Bob", @tanya)
    assert {:error, {:unknown_recipient, ["Tanya"]}} = resolve(nil)
    assert {:error, {:unknown_recipient, ["Tanya"]}} = resolve("")
  end

  test "first_name/1 prefers the first word of the name, else the email's local part" do
    assert Recipient.first_name(@tanya) == "Tanya"
    assert Recipient.first_name(%{name: nil, email: "sam@x.com"}) == "Sam"
    assert Recipient.first_name(%{name: "  ", email: "sam@x.com"}) == "Sam"
  end
end
