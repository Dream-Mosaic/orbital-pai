defmodule App.Camera do
  @moduledoc """
  One photo from the user's BOUND device, on request ("Henry, look at this" — spec
  2026-10-23-game-night-design, section 1).

  The wire protocol, fixed so the app and the server can be built apart:

  1. `request/2` registers the calling process under a fresh id in `App.Camera.Registry` and
     asks the session's Conversation to push `camera_capture` (`%{id, facing, countdown_ms}`)
     to its bound channel (`Conversation.camera_capture/3`). `facing` is "front" for a wall
     (`kiosk: true`), else "back".
  2. The app answers on the same topic with `camera_frame`; `AppWeb.VoiceChannel` decodes it
     and calls `deliver/2`, which hands the result to whoever waits on that id.
  3. After the vision call the caller sends `camera_done` (`done/1`) so the device can release
     the frozen snapshot. Every failure after the ask has been sent does it here instead, so a
     device is never left holding a frozen face it was not told to drop.
  4. No frame within 12 s → `{:error, :timeout}`. A frame for an unknown or expired id is
     ignored.

  Privacy: the JPEG lives only in the waiting process's memory. Nothing here stores or logs
  it; the one `[look]` line per capture (App.Tools.Look) carries sizes and timings only.
  """

  require Logger

  alias App.Conversations.{Conversation, Sessions}

  @registry App.Camera.Registry
  @wait_ms 12_000
  @countdown_ms 2_400

  @type capture :: %{
          id: String.t(),
          jpeg: binary(),
          client: pid(),
          facing: String.t(),
          capture_ms: non_neg_integer()
        }

  @type result :: {:ok, binary()} | {:error, term()}

  @doc "How long the device counts down before the shutter (the 3·2·1 in the orb)."
  @spec countdown_ms() :: pos_integer()
  def countdown_ms, do: @countdown_ms

  @doc """
  Ask the session's bound device for one photo and wait for it. Blocks the caller (a tool's
  task) for up to the wait (`:wait_ms`, default 12 s; app env `:camera_wait_ms` overrides it
  in tests). `:facing` is "front", "back" or `:auto` (the default: by the device's role).

  Returns `{:ok, capture}`, or `{:error, reason}`: `:no_device` (no live conversation or no
  live bound device), `:timeout`, `{:device, "no_camera" | "denied" | "failed" | other}`
  (the app's own answer), `:bad_frame` / `:too_large` (an unusable frame).
  """
  @spec request(String.t() | nil, keyword()) :: {:ok, capture()} | {:error, term()}
  def request(session_id, opts \\ [])

  def request(session_id, opts) when is_binary(session_id) do
    id = Ecto.UUID.generate()
    wait = Keyword.get_lazy(opts, :wait_ms, &wait_ms/0)
    facing = Keyword.get(opts, :facing, :auto)

    # Register BEFORE the ask goes out, so a fast device can never answer an id nobody holds.
    {:ok, _owner} = Registry.register(@registry, id, session_id)

    try do
      with {:ok, conversation} <- lookup(session_id),
           {:ok, %{client: client, facing: facing}} <- ask(conversation, id, facing) do
        await(id, client, facing, wait, System.monotonic_time(:millisecond))
      end
    after
      Registry.unregister(@registry, id)
    end
  end

  def request(_session_id, _opts), do: {:error, :no_device}

  @doc """
  Hand a device's answer to whoever waits on `id`. `:ignored` when nobody does — an id that
  never existed, or one whose wait already ended (the device answered too late).
  """
  @spec deliver(String.t(), result()) :: :ok | :ignored
  def deliver(id, result) when is_binary(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _session_id}] ->
        send(pid, {:camera_frame, id, result})
        :ok

      [] ->
        Logger.info("[look] a frame for an unknown or expired capture was ignored")
        :ignored
    end
  end

  def deliver(_id, _result), do: :ignored

  @doc """
  Tell the device that took `capture` it can release the frozen snapshot (`camera_done`).
  Sent to that device's channel, not to whichever device is bound by now: it is the one
  holding the photo.
  """
  @spec done(%{id: String.t(), client: pid()}) :: :ok
  def done(%{id: id, client: client}), do: release(client, id)

  defp await(id, client, facing, wait, started) do
    receive do
      {:camera_frame, ^id, {:ok, jpeg}} when is_binary(jpeg) ->
        {:ok,
         %{
           id: id,
           jpeg: jpeg,
           client: client,
           facing: facing,
           capture_ms: System.monotonic_time(:millisecond) - started
         }}

      {:camera_frame, ^id, {:error, reason}} ->
        release(client, id)
        {:error, reason}
    after
      wait ->
        release(client, id)
        {:error, :timeout}
    end
  end

  defp lookup(session_id) do
    case Sessions.lookup(session_id) do
      {:ok, pid} -> {:ok, pid}
      :error -> {:error, :no_device}
    end
  end

  # A Conversation that is exiting (or wedged past the call timeout) has no device to ask.
  defp ask(conversation, id, facing) do
    Conversation.camera_capture(conversation, id, facing)
  catch
    :exit, _reason -> {:error, :no_device}
  end

  defp release(client, id) do
    send(client, {:to_client, {:camera_done, id}})
    :ok
  end

  defp wait_ms, do: Application.get_env(:app, :camera_wait_ms, @wait_ms)
end
