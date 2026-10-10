defmodule App.Tools.MessagesTest do
  use App.DataCase, async: false

  alias App.Tools.Messages, as: Tool
  alias App.Users

  setup do
    Application.put_env(:app, :allowed_users, [
      %{email: "david@x.com", name: "David"},
      %{email: "tanya@x.com", name: "Tanya"}
    ])

    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, david} = Users.upsert_allowed("david@x.com")
    {:ok, tanya} = Users.upsert_allowed("tanya@x.com")
    %{david: david, tanya: tanya}
  end

  defp ctx(user),
    do: %{session_id: to_string(user.id), user_id: user.id, config: App.Config.default()}

  defp no_user, do: %{session_id: "default", user_id: nil, config: App.Config.default()}

  defp send_msg(ctx, to, message),
    do: Tool.execute("send_household_message", %{"to" => to, "message" => message}, ctx)

  test "is registered, declares both functions, and never bridges" do
    assert Tool in App.Config.default().tools
    names = Enum.map(Tool.declarations(), & &1.name)
    assert names == ["send_household_message", "check_household_messages"]

    [send_decl, _] = Tool.declarations()
    assert send_decl.parameters.required == ["to", "message"]

    assert Tool.bridge("send_household_message") == []
    assert Tool.bridge("check_household_messages") == []
  end

  test "prompt/0 teaches when to send, how to phrase it, and how to confirm" do
    p = Tool.prompt()
    assert p =~ "send_household_message"
    assert p =~ "check_household_messages"
    assert p =~ "delivery"
    assert p =~ ~r/never send/i
    # advertised through the registry's prompt block
    assert App.Tools.prompt_block(App.Config.default()) =~ p
  end

  describe "send_household_message" do
    test "sends to a household member and says it'll wait for them", %{david: d, tanya: t} do
      assert {:ok, %{sent: true, to: "Tanya", delivery: "next_time"} = res} =
               send_msg(ctx(d), "Tanya", "dinner's ready, come down")

      assert Jason.encode!(res)
      assert [%{body: "dinner's ready, come down"}] = App.Repo.all(App.Messages.Message)
      assert %{waiting_for_you: 1} = App.Messages.recent_status(t.id)
    end

    test "delivery is \"now\" when she's connected", %{david: d, tanya: t} do
      key = to_string(t.id)
      {:ok, _} = Registry.register(App.Conversations.Registry, key, nil)
      {:ok, _} = AppWeb.Presence.track(self(), "presence:voice", key, %{})

      assert {:ok, %{sent: true, delivery: "now"}} = send_msg(ctx(d), "tanya", "hi")

      :ok = AppWeb.Presence.untrack(self(), "presence:voice", key)
      :ok = Registry.unregister(App.Conversations.Registry, key)
    end

    test "dispatches through the registry", %{david: d} do
      assert {:ok, %{sent: true}} =
               App.Tools.execute(
                 "send_household_message",
                 %{"to" => "Tanya", "message" => "hi"},
                 ctx(d)
               )
    end

    test "an unknown name is a speakable result naming who CAN be messaged", %{david: d} do
      assert {:ok, %{sent: false, error: error, household: ["Tanya"]} = res} =
               send_msg(ctx(d), "Bob", "hi")

      assert error =~ "Bob"
      assert Jason.encode!(res)
      assert App.Repo.aggregate(App.Messages.Message, :count) == 0
    end

    test "messaging yourself, a blank or an over-long message are speakable refusals", %{
      david: d
    } do
      assert {:ok, %{sent: false, error: e1}} = send_msg(ctx(d), "David", "hi")
      assert e1 =~ ~r/yourself/i
      assert {:ok, %{sent: false, error: e2}} = send_msg(ctx(d), "Tanya", "  ")
      assert e2 =~ ~r/empty/i

      assert {:ok, %{sent: false, error: e3}} =
               send_msg(ctx(d), "Tanya", String.duplicate("a", 501))

      assert e3 =~ "500"
    end

    test "no user session: not sent, said so" do
      assert {:ok, %{sent: false, error: e}} = send_msg(no_user(), "Tanya", "hi")
      assert e =~ "no user session"
    end

    test "missing args is an error", %{david: d} do
      assert {:error, :missing_args} =
               Tool.execute("send_household_message", %{"to" => "Tanya"}, ctx(d))
    end
  end

  describe "check_household_messages" do
    test "my recent sent messages with delivered/pending, and what's waiting for me", %{
      david: d,
      tanya: t
    } do
      {:ok, %{message: m}} = App.Messages.send_message(d.id, "Tanya", "dinner's ready")
      App.Messages.mark_delivered(m.id)
      {:ok, _} = App.Messages.send_message(d.id, "Tanya", "bring the laundry up")
      {:ok, _} = App.Messages.send_message(t.id, "David", "on my way")

      assert {:ok, %{sent: [newest, oldest], waiting_for_you: 1} = res} =
               Tool.execute("check_household_messages", %{}, ctx(d))

      assert %{to: "Tanya", message: "bring the laundry up", delivered: false} = newest
      assert %{to: "Tanya", message: "dinner's ready", delivered: true} = oldest
      assert Jason.encode!(res)
    end

    test "no user session: nothing to report" do
      assert {:ok, %{sent: [], waiting_for_you: 0}} =
               Tool.execute("check_household_messages", %{}, no_user())
    end
  end
end
