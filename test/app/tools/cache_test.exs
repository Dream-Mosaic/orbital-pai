defmodule App.Tools.CacheTest do
  # async: false — shares the app-wide ETS table.
  use ExUnit.Case, async: false
  alias App.Tools.Cache

  setup do
    Cache.clear()
    :ok
  end

  test "put then get returns the cached {:ok, _}" do
    key = {"default", "get_weather", %{"location" => "STL"}}
    assert Cache.put(key, {:ok, %{temp: 70}}, 50_000) == :ok
    assert Cache.get(key) == {:ok, %{temp: 70}}
  end

  test "get past expiry is a miss (and evicts)" do
    key = {"default", "get_weather", %{}}
    Cache.put(key, {:ok, %{a: 1}}, 50)
    future = System.monotonic_time(:millisecond) + 10_000
    assert Cache.get(key, future) == nil
    assert Cache.get(key) == nil
  end

  test "errors and nil-ttl are never stored" do
    k1 = {"default", "x", %{}}
    k2 = {"default", "y", %{}}
    assert Cache.put(k1, {:error, :boom}, 50_000) == :ok
    assert Cache.put(k2, {:ok, %{}}, nil) == :ok
    assert Cache.get(k1) == nil
    assert Cache.get(k2) == nil
  end

  test "purge removes every entry for a tool name, regardless of session/args" do
    Cache.put({"default", "get_calendar_events", %{"d" => 1}}, {:ok, %{}}, 50_000)
    Cache.put({"s2", "get_calendar_events", %{"d" => 2}}, {:ok, %{}}, 50_000)
    Cache.put({"default", "get_weather", %{}}, {:ok, %{}}, 50_000)

    assert Cache.purge("get_calendar_events") == :ok
    assert Cache.get({"default", "get_calendar_events", %{"d" => 1}}) == nil
    assert Cache.get({"s2", "get_calendar_events", %{"d" => 2}}) == nil
    assert Cache.get({"default", "get_weather", %{}}) == {:ok, %{}}
  end

  test "missing key returns nil" do
    assert Cache.get({"default", "nope", %{}}) == nil
  end
end
