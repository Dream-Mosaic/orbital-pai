defmodule App.MessagesTest do
  use App.DataCase, async: false

  alias App.Agenda.Item
  alias App.Messages
  alias App.Messages.Message
  alias App.Users

  setup do
    Application.put_env(:app, :allowed_users, [
      %{email: "david@x.com", name: "David Clausen"},
      %{email: "tanya@x.com", name: "Tanya Clausen", aliases: ["teedee@y.com"]}
    ])

    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, david} = Users.upsert_allowed("david@x.com")
    {:ok, tanya} = Users.upsert_allowed("tanya@x.com")
    %{david: david, tanya: tanya}
  end

  describe "send_message/3 — resolution" do
    test "resolves the OTHER user by first name, case-insensitively", %{david: d, tanya: t} do
      assert {:ok, %{message: %Message{} = m, recipient_name: "Tanya", live?: false}} =
               Messages.send_message(d.id, "tanya", "dinner's ready")

      assert m.from_user_id == d.id
      assert m.to_user_id == t.id
      assert m.body == "dinner's ready"
      assert m.delivered_at == nil
    end

    test "resolves by full name, email local part and alias", %{david: d, tanya: t} do
      for to <- ["Tanya Clausen", "TANYA", "teedee", " Tanya. "] do
        assert {:ok, %{message: %{to_user_id: id}}} = Messages.send_message(d.id, to, "hi")
        assert id == t.id, "expected #{inspect(to)} to reach Tanya"
      end
    end

    test "works in both directions", %{david: d, tanya: t} do
      assert {:ok, %{message: %{to_user_id: id}, recipient_name: "David"}} =
               Messages.send_message(t.id, "David", "on my way")

      assert id == d.id
    end

    test "is NOT gated on household_named_targets (a message isn't a write into their data)",
         %{david: d} do
      refute App.Config.default().household_named_targets
      assert {:ok, _} = Messages.send_message(d.id, "Tanya", "hi")
    end

    test "naming yourself is {:error, :self}", %{david: d} do
      assert {:error, :self} = Messages.send_message(d.id, "David", "hi")
      assert {:error, :self} = Messages.send_message(d.id, "me", "hi")
      assert Repo.aggregate(Message, :count) == 0
    end

    test "an unknown name names the valid recipients", %{david: d} do
      assert {:error, {:unknown_recipient, ["Tanya"]}} =
               Messages.send_message(d.id, "Bob", "hi")
    end

    test "a user row that is no longer allowlisted can't be messaged", %{david: d} do
      %Users.User{} |> Users.User.changeset(%{email: "bob@x.com", name: "Bob"}) |> Repo.insert!()

      assert {:error, {:unknown_recipient, ["Tanya"]}} =
               Messages.send_message(d.id, "Bob", "hi")
    end

    test "a blank body is {:error, :blank}", %{david: d} do
      assert {:error, :blank} = Messages.send_message(d.id, "Tanya", "   ")
      assert {:error, :blank} = Messages.send_message(d.id, "Tanya", nil)
    end

    test "bodies are capped at 500 characters", %{david: d} do
      assert {:ok, _} = Messages.send_message(d.id, "Tanya", String.duplicate("a", 500))

      assert {:error, :too_long} =
               Messages.send_message(d.id, "Tanya", String.duplicate("a", 501))
    end
  end

  describe "send_message/3 — delivery" do
    test "broadcasts a canned :message agenda item on the recipient's agenda topic",
         %{david: d, tanya: t} do
      Phoenix.PubSub.subscribe(App.PubSub, "agenda:#{t.id}")
      {:ok, %{message: m}} = Messages.send_message(d.id, "Tanya", "dinner's ready")

      assert_receive {:agenda_due, %Item{kind: :message, canned: true} = item}
      assert item.prompt == "dinner's ready."
      assert item.lead_idle == "Message from David —"
      assert item.ack == {Messages, :mark_delivered, [m.id]}
    end

    test "live? is true only while the recipient has a session AND a connected device",
         %{david: d, tanya: t} do
      key = to_string(t.id)
      {:ok, _} = Registry.register(App.Conversations.Registry, key, nil)

      # a lingering session (no device connected) is not "around": she'd hear nothing
      assert {:ok, %{live?: false}} = Messages.send_message(d.id, "Tanya", "one")

      {:ok, _} = AppWeb.Presence.track(self(), "presence:voice", key, %{})
      assert {:ok, %{live?: true}} = Messages.send_message(d.id, "Tanya", "two")

      # synchronously, so the next test (whose users may reuse these ids) starts clean
      :ok = AppWeb.Presence.untrack(self(), "presence:voice", key)
      :ok = Registry.unregister(App.Conversations.Registry, key)
    end
  end

  describe "item/1" do
    test "a canned, :when_idle, non-expiring item that persists with context", %{
      david: d,
      tanya: t
    } do
      m = insert_message(d, t, "dinner's ready, come down")
      item = Messages.item(m)

      assert %Item{
               kind: :message,
               canned: true,
               deliver: :when_idle,
               expires_at: nil,
               prompt: "dinner's ready, come down.",
               lead_idle: "Message from David —",
               lead_interjected: "Oh — a message from David —",
               persist_as: "(message from David: dinner's ready, come down)"
             } = item

      assert item.ack == {Messages, :mark_delivered, [m.id]}
    end

    test "terminal punctuation is kept, not doubled", %{david: d, tanya: t} do
      for {body, spoken} <- [
            {"come down!", "come down!"},
            {"you there?", "you there?"},
            {"done.", "done."},
            {"so…", "so…"},
            {"see you at 5", "see you at 5."}
          ] do
        assert Messages.item(insert_message(d, t, body)).prompt == spoken
      end
    end
  end

  describe "mark_delivered/1" do
    test "stamps delivered_at once; a second call leaves the first stamp", %{david: d, tanya: t} do
      m = insert_message(d, t, "hi")
      assert :ok = Messages.mark_delivered(m.id)
      first = Repo.get!(Message, m.id).delivered_at
      assert %DateTime{} = first

      assert :ok = Messages.mark_delivered(m.id)
      assert Repo.get!(Message, m.id).delivered_at == first
    end
  end

  describe "pull/1" do
    test "the session user's undelivered messages, oldest first, as items", %{
      david: d,
      tanya: t
    } do
      m1 = insert_message(d, t, "first", ~U[2026-10-10 09:00:00.000000Z])
      m2 = insert_message(d, t, "second", ~U[2026-10-10 09:05:00.000000Z])
      m0 = insert_message(d, t, "already heard", ~U[2026-10-10 08:00:00.000000Z])
      Messages.mark_delivered(m0.id)
      # David's own inbox is separate
      insert_message(t, d, "for david")

      assert [%Item{} = i1, %Item{} = i2] = Messages.pull(to_string(t.id))
      assert i1.ack == {Messages, :mark_delivered, [m1.id]}
      assert i2.ack == {Messages, :mark_delivered, [m2.id]}
    end

    test "non-user sessions pull nothing" do
      assert Messages.pull("default") == []
      assert Messages.pull(nil) == []
    end
  end

  describe "recent_status/1" do
    test "my last few sent (newest first, with delivered + when) and my waiting count", %{
      david: d,
      tanya: t
    } do
      now = DateTime.utc_now()
      old = insert_message(d, t, "old one", DateTime.add(now, -3 * 3600, :second))
      Messages.mark_delivered(old.id)
      insert_message(d, t, "new one", DateTime.add(now, -120, :second))
      insert_message(t, d, "waiting for david")

      assert %{sent: [newest, oldest], waiting_for_you: 1} = Messages.recent_status(d.id)

      assert %{to: "Tanya", message: "new one", delivered: false, sent: "2 minutes ago"} =
               newest

      assert %{to: "Tanya", message: "old one", delivered: true, sent: "3 hours ago"} = oldest
      assert is_binary(oldest.delivered_when)
      assert newest.delivered_when == nil
    end

    test "caps the sent list at 5", %{david: d, tanya: t} do
      for i <- 1..7, do: insert_message(d, t, "m#{i}")
      assert %{sent: sent} = Messages.recent_status(d.id)
      assert length(sent) == 5
    end
  end

  test "ago/2 renders a short spoken relative time" do
    now = ~U[2026-10-10 12:00:00Z]
    assert Messages.ago(DateTime.add(now, -10, :second), now) == "just now"
    assert Messages.ago(DateTime.add(now, -60, :second), now) == "1 minute ago"
    assert Messages.ago(DateTime.add(now, -45 * 60, :second), now) == "45 minutes ago"
    assert Messages.ago(DateTime.add(now, -3600, :second), now) == "1 hour ago"
    assert Messages.ago(DateTime.add(now, -5 * 3600, :second), now) == "5 hours ago"
    assert Messages.ago(DateTime.add(now, -30 * 3600, :second), now) == "yesterday"
    assert Messages.ago(DateTime.add(now, -4 * 86_400, :second), now) == "4 days ago"
  end

  defp insert_message(from, to, body, at \\ nil) do
    m =
      %Message{}
      |> Message.changeset(%{from_user_id: from.id, to_user_id: to.id, body: body})
      |> Repo.insert!()

    if at do
      m |> Ecto.Changeset.change(inserted_at: at, updated_at: at) |> Repo.update!()
    else
      m
    end
  end
end
