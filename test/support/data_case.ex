defmodule App.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use App.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias App.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import App.DataCase
    end
  end

  setup tags do
    App.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(App.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    # `on_exit` runs LIFO, so this drain (registered AFTER stop_owner) runs BEFORE it — while the
    # shared sandbox owner is still alive. Conversation FSMs persist turns + run the memory updater
    # in async tasks on the GLOBAL `App.Conversations.TaskSup`, which can outlive the test that
    # spawned them. If one is still using the shared connection when `stop_owner` fires, it pins the
    # owner's open transaction (holding SQLite's single write lock) into the NEXT test → that test's
    # first write burns the 5s `busy_timeout` and raises "Database busy". Draining while the owner
    # still lives lets those tasks finish cleanly. Shared (sync) suites only — async files use
    # isolated owners and must not wait on each other's global tasks.
    unless tags[:async], do: on_exit(&drain_conversation_tasks/0)
  end

  @doc """
  Wait for the global Conversation task supervisor to quiesce (see `setup_sandbox/1`). Polls until
  it has no children, or force-terminates stragglers past the deadline (should never fire — with the
  sandbox owner still alive during the drain there's a single writer, so tasks finish in a poll or two).
  """
  def drain_conversation_tasks(deadline_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    drain_loop(App.Conversations.TaskSup, deadline)
  end

  defp drain_loop(sup, deadline) do
    case Task.Supervisor.children(sup) do
      [] ->
        :ok

      pids ->
        if System.monotonic_time(:millisecond) >= deadline do
          Enum.each(pids, &Task.Supervisor.terminate_child(sup, &1))
        else
          Process.sleep(20)
          drain_loop(sup, deadline)
        end
    end
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
