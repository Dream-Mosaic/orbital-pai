defmodule App.Auth.AppCodeTest do
  use ExUnit.Case, async: false

  alias App.Auth.AppCode

  setup do
    start_supervised!({AppCode, name: :test_app_code, ttl_ms: 200})
    :ok
  end

  test "a minted code exchanges once for its user id" do
    code = AppCode.mint(:test_app_code, 42)
    assert {:ok, 42} = AppCode.exchange(:test_app_code, code)
  end

  # Single-use is the whole security property: a code captured from a browser history or an
  # intent log must be dead by the time anyone replays it.
  test "the same code cannot be exchanged twice" do
    code = AppCode.mint(:test_app_code, 42)
    assert {:ok, 42} = AppCode.exchange(:test_app_code, code)
    assert {:error, :invalid} = AppCode.exchange(:test_app_code, code)
  end

  test "an expired code is refused" do
    code = AppCode.mint(:test_app_code, 42)
    Process.sleep(260)
    assert {:error, :invalid} = AppCode.exchange(:test_app_code, code)
  end

  test "an unknown code is refused" do
    assert {:error, :invalid} = AppCode.exchange(:test_app_code, "never-minted")
  end

  # Distinct users must never collide, and one user's code must not yield another's id.
  test "codes are per-user and unguessable" do
    a = AppCode.mint(:test_app_code, 1)
    b = AppCode.mint(:test_app_code, 2)
    refute a == b
    assert byte_size(a) >= 32
    assert {:ok, 2} = AppCode.exchange(:test_app_code, b)
    assert {:ok, 1} = AppCode.exchange(:test_app_code, a)
  end
end
