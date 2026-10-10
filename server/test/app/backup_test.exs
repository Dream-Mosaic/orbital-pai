defmodule App.BackupTest do
  # async: false -- VACUUM INTO must run outside the sandbox transaction (unboxed_run).
  use App.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox

  setup do
    dir = Path.join(System.tmp_dir!(), "henry-backup-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "snapshot/1 writes a complete, openable copy of the database named for today", %{dir: dir} do
    assert {:ok, path} = Sandbox.unboxed_run(App.Repo, fn -> App.Backup.snapshot(dir: dir) end)

    assert Path.basename(path) =~ ~r/^app-\d{4}-\d{2}-\d{2}\.db$/
    assert File.stat!(path).size > 0
    # it's a real SQLite file with the schema in it
    assert {:ok, <<"SQLite format 3", 0>>} =
             File.open(path, [:read, :binary], &IO.binread(&1, 16))
  end

  test "a second snapshot the same day replaces the first rather than failing", %{dir: dir} do
    assert {:ok, path} = Sandbox.unboxed_run(App.Repo, fn -> App.Backup.snapshot(dir: dir) end)
    assert {:ok, ^path} = Sandbox.unboxed_run(App.Repo, fn -> App.Backup.snapshot(dir: dir) end)
    assert App.Backup.list(dir) == [path]
  end

  test "only the newest `keep` snapshots survive; unrelated files are left alone", %{dir: dir} do
    File.mkdir_p!(dir)

    for d <- ~w(2026-01-01 2026-01-02 2026-01-03),
        do: File.write!(Path.join(dir, "app-#{d}.db"), "x")

    File.write!(Path.join(dir, "notes.txt"), "keep me")

    assert {:ok, today} =
             Sandbox.unboxed_run(App.Repo, fn -> App.Backup.snapshot(dir: dir, keep: 2) end)

    assert App.Backup.list(dir) == [today, Path.join(dir, "app-2026-01-03.db")]
    assert File.exists?(Path.join(dir, "notes.txt"))
  end

  test "list/1 of a missing directory is empty" do
    assert App.Backup.list("/nonexistent/henry/backups") == []
  end
end
