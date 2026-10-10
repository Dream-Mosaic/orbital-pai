defmodule App.Agenda.WhatsNewTest do
  use App.DataCase, async: false

  alias App.Agenda.{Item, WhatsNew}
  alias App.Users

  setup do
    Application.put_env(:app, :whats_new, true)
    on_exit(fn -> Application.put_env(:app, :whats_new, false) end)

    Application.put_env(:app, :allowed_users, [
      %{email: "d@x.com", name: "David Clausen"},
      %{email: "t@x.com", name: "Tanya Clausen"}
    ])

    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, d} = Users.upsert_allowed("d@x.com")
    {:ok, t} = Users.upsert_allowed("t@x.com")
    %{d: d, t: t}
  end

  test "a user who hasn't heard this release gets one canned, after-next-turn note", %{d: d} do
    assert %Item{kind: :news, canned: true, deliver: :after_next_turn, prompt: prompt} =
             WhatsNew.pull(to_string(d.id))

    # it names the OTHER person in the house, by first name, as something to say
    assert prompt =~ ~s(tell Tanya)
    assert prompt =~ "kitchen timers"
  end

  test "once it's been spoken (the ack), it isn't offered again until the next release", %{t: t} do
    %Item{ack: {m, f, a}} = WhatsNew.pull(to_string(t.id))
    apply(m, f, a)
    assert WhatsNew.pull(to_string(t.id)) == nil
    assert Users.get(t.id).whats_new_seen == WhatsNew.release()
  end

  test "no user, or the feature off, means nothing", %{d: d} do
    assert WhatsNew.pull("default") == nil
    Application.put_env(:app, :whats_new, false)
    assert WhatsNew.pull(to_string(d.id)) == nil
  end
end
