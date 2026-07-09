defmodule App.AgendaTest do
  use ExUnit.Case, async: true

  alias App.Agenda
  alias App.Agenda.Item
  alias App.Reminders.Reminder

  test "reminder_item/1 maps a reminder to an Item with today's exact notice text" do
    r = %Reminder{id: 7, user_id: 3, body: "check the weather"}
    item = Agenda.reminder_item(r)

    assert %Item{kind: :reminder, deliver: :when_idle, recent_context: false, persist_as: nil} =
             item

    assert item.lead_idle == "Heads up —"
    assert item.lead_interjected == "Oh, before I forget —"
    assert item.prompt =~ ~s|A reminder you set earlier just came due: "check the weather"|
    assert item.prompt =~ "If it's not something you can do, just remind me of it, briefly."
    assert item.ack == {App.Reminders, :acknowledge, [r]}
    assert item.expires_at == nil
  end

  test "expired?/1" do
    refute Agenda.expired?(%Item{kind: :x, prompt: "p"})
    refute Agenda.expired?(%Item{kind: :x, prompt: "p", expires_at: minutes_from_now(5)})
    assert Agenda.expired?(%Item{kind: :x, prompt: "p", expires_at: minutes_from_now(-5)})
  end

  test "deliver/2 broadcasts {:agenda_due, item} on agenda:<user_id>" do
    Phoenix.PubSub.subscribe(App.PubSub, "agenda:42")
    item = %Item{kind: :reminder, prompt: "p"}
    assert :ok = Agenda.deliver(42, item)
    assert_receive {:agenda_due, ^item}
  end

  defp minutes_from_now(m), do: DateTime.add(DateTime.utc_now(), m * 60, :second)
end
