defmodule AppWeb.AppLinkTest do
  use ExUnit.Case, async: true

  alias AppWeb.AppLink

  test "an :info outcome becomes an ok status" do
    assert AppLink.connectors(:info) == "orbital://connectors?status=ok"
  end

  test "an :error outcome becomes an error status" do
    assert AppLink.connectors(:error) == "orbital://connectors?status=error"
  end

  # Only :info means success. Anything else is a failure the app must not render as a
  # connection, so the mapping is an allowlist of one rather than a match on :error.
  test "an unrecognized outcome is treated as a failure, not as success" do
    assert AppLink.connectors(:something_new) == "orbital://connectors?status=error"
  end

  # The scheme is duplicated in AndroidManifest.xml and deep_link.dart by necessity (three
  # different languages, one string). This pins the value so a change here is a visible,
  # deliberate edit that sends someone to update the other two.
  test "the link uses the orbital scheme and the connectors host" do
    assert AppLink.connectors(:info) |> URI.parse() |> then(&{&1.scheme, &1.host}) ==
             {"orbital", "connectors"}
  end
end
