defmodule App.Speaker.Ortex do
  @moduledoc """
  In-BEAM speaker-embedding verifier: the WeSpeaker ECAPA ONNX model under Ortex.
  Loads at boot (async continue); a missing model file leaves it not-ready and every
  caller fails open — Voice Lock malfunctioning must degrade to "works like today".
  """
  @behaviour App.Speaker.Verifier
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl App.Speaker.Verifier
  def embed(pcm16) when is_binary(pcm16) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      # Fbank.compute/1 is pure-Nx on the default (non-EXLA) BinaryBackend — measured
      # ~5.2s for a ~14s clip on this box, so a tight 5s call timeout false-fails.
      # 15s leaves headroom until that gets an EXLA/precomputed-filterbank speedup.
      pid -> GenServer.call(pid, {:embed, pcm16}, 15_000)
    end
  catch
    :exit, reason -> {:error, {:call_failed, reason}}
  end

  @impl App.Speaker.Verifier
  def ready? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> GenServer.call(pid, :ready?, 1_000)
    end
  catch
    :exit, _ -> false
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{model: nil}, {:continue, :load}}

  @impl GenServer
  def handle_continue(:load, state) do
    path = Application.get_env(:app, :speaker_model_path, "priv/models/speaker_ecapa.onnx")

    if File.exists?(path) do
      model = Ortex.load(path)
      Logger.info("[speaker] model loaded (#{path})")
      {:noreply, %{state | model: model}}
    else
      Logger.warning(
        "[speaker] model file missing (#{path}) — verifier not ready, gate fails open"
      )

      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_call(:ready?, _from, state), do: {:reply, state.model != nil, state}

  def handle_call({:embed, _pcm}, _from, %{model: nil} = state),
    do: {:reply, {:error, :model_not_loaded}, state}

  def handle_call({:embed, pcm16}, _from, state) do
    reply =
      try do
        feats = pcm16 |> App.Speaker.Fbank.compute() |> Nx.new_axis(0)
        {out} = Ortex.run(state.model, feats)
        vec = out[0] |> Nx.to_flat_list()
        norm = :math.sqrt(Enum.reduce(vec, 0.0, &(&2 + &1 * &1)))
        if norm > 0.0, do: {:ok, Enum.map(vec, &(&1 / norm))}, else: {:error, :zero_embedding}
      rescue
        e -> {:error, {:embed_failed, Exception.message(e)}}
      end

    {:reply, reply, state}
  end
end
