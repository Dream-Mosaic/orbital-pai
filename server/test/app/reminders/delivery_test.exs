defmodule App.Reminders.DeliveryTest do
  use ExUnit.Case, async: true
  alias App.Reminders.Delivery

  defp meta(kiosk?), do: %{metas: [%{name: "x", kiosk: kiosk?, online_at: 0}]}

  test "prefers the kiosk (wall) user" do
    presence = %{"5" => meta(false), "3" => meta(true)}
    assert Delivery.target(presence) == 3
  end

  test "no kiosk -> any active member, deterministically the lowest user_id" do
    presence = %{"7" => meta(false), "4" => meta(false)}
    assert Delivery.target(presence) == 4
  end

  test "nobody connected -> nil" do
    assert Delivery.target(%{}) == nil
  end
end
