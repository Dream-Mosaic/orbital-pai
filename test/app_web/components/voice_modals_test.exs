defmodule AppWeb.VoiceModalsTest do
  use ExUnit.Case, async: true
  alias AppWeb.VoiceModals

  test "fmt_due renders in the configured timezone" do
    # America/Chicago is UTC-5 in July (CDT)
    assert VoiceModals.fmt_due(~U[2026-07-05 23:30:00Z]) == "Jul 5 6:30pm"
  end
end
