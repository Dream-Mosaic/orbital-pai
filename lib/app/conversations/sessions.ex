defmodule App.Conversations.Sessions do
  @moduledoc """
  Start / look up / stop a per-session `Conversation` under the DynamicSupervisor,
  registered in the Registry by `session_id`. Crash isolation: a session that dies
  is restarted (`:transient`) or cleaned up without affecting others.
  """
  alias App.Conversations.Conversation
  alias App.Config

  @sup App.Conversations.Sup
  @registry App.Conversations.Registry

  @spec start(String.t(), pid(), Config.t()) :: DynamicSupervisor.on_start_child()
  def start(session_id, client, config \\ Config.default()) do
    spec =
      {Conversation,
       name: via(session_id), client: client, session_id: session_id, config: config}

    DynamicSupervisor.start_child(@sup, spec)
  end

  @spec lookup(String.t()) :: {:ok, pid()} | :error
  def lookup(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @spec stop(String.t()) :: :ok
  def stop(session_id) do
    case lookup(session_id) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(@sup, pid)
      :error -> :ok
    end

    :ok
  end

  defp via(session_id), do: {:via, Registry, {@registry, session_id}}
end
