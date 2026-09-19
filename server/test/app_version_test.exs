defmodule App.VersionTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "the running version is priv/VERSION, not the frozen mix.exs vsn" do
    # Issue #1: the version moved out of mix.exs so a bump stops busting the Docker deps cache.
    expected = File.read!(Path.expand("../priv/VERSION", __DIR__)) |> String.trim()
    assert App.version() == expected
  end

  test "a trimmed VERSION file is read as-is", %{tmp_dir: dir} do
    path = Path.join(dir, "VERSION")
    File.write!(path, "  1.2.3\n")
    assert App.read_version(path) == "1.2.3"
  end

  test "a missing or blank file falls back to the mix.exs vsn rather than crashing",
       %{tmp_dir: dir} do
    vsn = :app |> Application.spec(:vsn) |> to_string()
    assert App.read_version(Path.join(dir, "absent")) == vsn

    blank = Path.join(dir, "VERSION")
    File.write!(blank, "\n")
    assert App.read_version(blank) == vsn
  end
end
