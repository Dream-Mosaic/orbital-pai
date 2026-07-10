defmodule App.Test.Fakes do
  @moduledoc "Controllable fakes for Conversation tests."

  defmodule Tts do
    @moduledoc "Returns a tiny fixed PCM16 clip (160 samples = ~10ms @ 16kHz)."
    @behaviour App.Adapters.Tts

    @impl true
    def synthesize(_text, _opts), do: {:ok, :binary.copy(<<0, 0>>, 160)}
  end

  defmodule BrainStream do
    @moduledoc """
    Fake streaming brain: emits one tiny audio chunk then `{:brain_done, "the answer"}`.
    Set `:fake_brain_done_ms` to delay the done (so a test can barge in mid-stream).
    """
    use GenServer

    def start(opts), do: GenServer.start(__MODULE__, opts)
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def begin(pid, transcript, recent_context),
      do: GenServer.cast(pid, {:begin, transcript, recent_context})

    @impl true
    def init(opts) do
      case Keyword.get(opts, :transcript) do
        nil ->
          # pre-warm: no transcript yet — announce and wait for begin/3
          if pid = Process.whereis(:fake_brain_observer), do: send(pid, {:fake_brain_prewarmed})
          {:ok, %{owner: Keyword.fetch!(opts, :owner)}}

        transcript ->
          notify_observer(transcript, Keyword.get(opts, :recent_context, true))
          {:ok, %{owner: Keyword.fetch!(opts, :owner)}, {:continue, :emit}}
      end
    end

    @impl true
    def handle_cast({:begin, transcript, recent_context}, state) do
      notify_observer(transcript, recent_context)
      {:noreply, state, {:continue, :emit}}
    end

    defp notify_observer(transcript, recent_context) do
      if pid = Process.whereis(:fake_brain_observer) do
        send(pid, {:fake_brain_transcript, transcript})
        send(pid, {:fake_brain_recent_context, recent_context})
      end
    end

    @impl true
    def handle_continue(:emit, state) do
      if Application.get_env(:app, :fake_brain_error, false) do
        send(state.owner, {:brain_error, :fake})
        {:stop, :normal, state}
      else
        emit_audio(state)
      end
    end

    defp emit_audio(state) do
      send(state.owner, {:brain_audio, :binary.copy(<<0, 0>>, 160)})

      for d <- Application.get_env(:app, :fake_brain_text_deltas, []),
          do: send(state.owner, {:brain_text, d})

      case Application.get_env(:app, :fake_brain_done_ms, 0) do
        0 ->
          send(state.owner, {:brain_done, done_text()})
          {:stop, :normal, state}

        ms ->
          Process.send_after(self(), :do_done, ms)
          {:noreply, state}
      end
    end

    @impl true
    def handle_info(:do_done, state) do
      send(state.owner, {:brain_done, done_text()})
      {:stop, :normal, state}
    end

    # `:fake_brain_done_text` lets a test force an empty (or custom) final answer — the prod
    # empty-brain case where the model ran tools but produced no spoken text.
    defp done_text, do: Application.get_env(:app, :fake_brain_done_text, "the answer")
  end

  defmodule Stt do
    @moduledoc "No-op STT: starts a process, swallows pushed audio. Tests drive turns directly."
    @behaviour App.Adapters.Stt
    use GenServer

    @impl App.Adapters.Stt
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl App.Adapters.Stt
    def push(pid, pcm16), do: GenServer.cast(pid, {:push, pcm16})

    @impl App.Adapters.Stt
    def finalize(pid), do: GenServer.cast(pid, :finalize)

    @impl GenServer
    def init(opts) do
      if pid = Process.whereis(:fake_stt_observer) do
        send(pid, {:fake_stt_started, Keyword.get(opts, :mode, :auto)})
      end

      {:ok, %{owner: Keyword.fetch!(opts, :owner)}}
    end

    # Tests can observe the inbound audio path by registering `:fake_stt_observer`.
    @impl GenServer
    def handle_cast({:push, pcm}, state) do
      case Process.whereis(:fake_stt_observer) do
        nil -> :ok
        pid -> send(pid, {:fake_stt_push, pcm})
      end

      {:noreply, state}
    end

    @impl GenServer
    def handle_cast(:finalize, state) do
      case Process.whereis(:fake_stt_observer) do
        nil -> :ok
        pid -> send(pid, {:fake_stt_finalize})
      end

      {:noreply, state}
    end
  end

  defmodule FakeTool do
    @moduledoc "A trivial tool for registry tests: echoes its arg."
    @behaviour App.Tools.Tool

    @impl true
    def declarations do
      [
        %{
          name: "echo",
          description: "Echo a message back.",
          parameters: %{
            type: "object",
            properties: %{msg: %{type: "string", description: "Message to echo."}},
            required: ["msg"]
          }
        }
      ]
    end

    @impl true
    def execute("echo", %{"msg" => msg}, _ctx), do: {:ok, %{echoed: msg}}
  end

  defmodule SlowTool do
    @moduledoc "A tool that never returns in time — for the registry timeout test."
    @behaviour App.Tools.Tool

    @impl true
    def declarations do
      [
        %{
          name: "slow",
          description: "Sleeps forever.",
          parameters: %{type: "object", properties: %{}, required: []}
        }
      ]
    end

    @impl true
    def execute("slow", _args, _ctx) do
      Process.sleep(60_000)
      {:ok, %{}}
    end

    # A short per-tool cap so execute/3 (no explicit timeout) aborts fast in the registry test.
    @impl true
    def timeout("slow"), do: 40
  end

  defmodule CrashTool do
    @moduledoc "Raises — for the registry crash-mapping test."
    @behaviour App.Tools.Tool

    @impl true
    def declarations do
      [
        %{
          name: "crash",
          description: "Raises.",
          parameters: %{type: "object", properties: %{}, required: []}
        }
      ]
    end

    @impl true
    def execute("crash", _args, _ctx), do: raise("boom")
  end

  defmodule BadReturnTool do
    @moduledoc "Returns a non-conforming value — for the registry bad-return test."
    @behaviour App.Tools.Tool

    @impl true
    def declarations do
      [
        %{
          name: "bad",
          description: "Bad return.",
          parameters: %{type: "object", properties: %{}, required: []}
        }
      ]
    end

    @impl true
    def execute("bad", _args, _ctx), do: :not_a_tuple
  end

  defmodule CacheTool do
    @behaviour App.Tools.Tool

    @impl true
    def declarations do
      for n <- ~w(cached_read uncached_read cache_write err_read err_write) do
        %{name: n, description: n, parameters: %{type: "object", properties: %{}, required: []}}
      end
    end

    # unique value per call → a cached 2nd call returns the SAME value; a fresh call differs.
    @impl true
    def execute("cached_read", _args, _ctx), do: {:ok, %{val: System.unique_integer([:positive])}}

    def execute("uncached_read", _args, _ctx),
      do: {:ok, %{val: System.unique_integer([:positive])}}

    def execute("cache_write", _args, _ctx), do: {:ok, %{ok: true}}
    def execute("err_read", _args, _ctx), do: {:error, :boom}
    def execute("err_write", _args, _ctx), do: {:error, :nope}

    @impl true
    def cache_ttl("cached_read"), do: 50_000
    def cache_ttl("err_read"), do: 50_000
    def cache_ttl(_), do: nil

    @impl true
    def cache_invalidates("cache_write"), do: ["cached_read"]
    def cache_invalidates("err_write"), do: ["cached_read"]
    def cache_invalidates(_), do: []

    # drop a volatile arg from the cache key so calls differing only by it collide.
    @impl true
    def cache_key("cached_read", args), do: Map.drop(args, ["volatile"])
    def cache_key(_name, args), do: args
  end
end
