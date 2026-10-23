defmodule App.CameraTest do
  # async: false — a session-bound Conversation runs DB pulls right after init (shared
  # sandbox), and one test changes the global camera wait.
  use ExUnit.Case, async: false

  alias App.Camera
  alias App.Conversations.Conversation

  # "Henry, look at this" (spec 2026-10-23-game-night-design, section 1): the server asks the
  # BOUND device for one photo and waits for it; the channel hands the frame back by id.

  setup do
    App.DataCase.setup_sandbox(%{async: false})
    %{sid: "camera-#{System.unique_integer([:positive])}"}
  end

  # Registered under `sid` exactly as Sessions.start/3 registers it, so App.Camera finds it.
  defp start_session(sid, client) do
    {:ok, pid} =
      Conversation.start_link(
        client: client,
        config: %App.Config{},
        session_id: sid,
        name: {:via, Registry, {App.Conversations.Registry, sid}}
      )

    on_exit(fn -> stop_session(pid) end)
    pid
  end

  # Synchronous, so the init pulls can't outlive the sandbox owner (see conversation_test.exs).
  defp stop_session(pid) do
    if Process.alive?(pid) do
      App.DataCase.drain_conversation_tasks()
      :gen_statem.stop(pid, :normal, 2_000)
    end
  catch
    :exit, _ -> :ok
  end

  # A stand-in for the bound device's channel: tells the test what it was asked, then answers
  # the capture with `reply` (or never, for :silent).
  defp device(reply) do
    test = self()
    spawn_link(fn -> device_loop(test, reply) end)
  end

  defp device_loop(test, reply) do
    receive do
      {:to_client, {:camera_capture, id, facing}} ->
        send(test, {:asked, id, facing})
        if reply != :silent, do: Camera.deliver(id, reply)
        device_loop(test, reply)

      {:to_client, {:camera_done, id}} ->
        send(test, {:done, id})
        device_loop(test, reply)

      _other ->
        device_loop(test, reply)
    end
  end

  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, "fake jpeg body">>

  test "asks the bound device and returns the frame it sends back", %{sid: sid} do
    dev = device({:ok, @jpeg})
    start_session(sid, dev)

    assert {:ok, %{id: id, jpeg: @jpeg, client: ^dev, facing: "back"} = capture} =
             Camera.request(sid)

    assert is_binary(id) and byte_size(id) == 36
    assert is_integer(capture.capture_ms)
    assert_received {:asked, ^id, "back"}
  end

  test "a wall (kiosk) device is asked for its front camera", %{sid: sid} do
    dev = device({:ok, @jpeg})
    pid = start_session(sid, dev)
    :gen_statem.cast(pid, {:device_role, dev, %{kiosk: true, shared: true}})

    assert {:ok, %{facing: "front"}} = Camera.request(sid)
    assert_received {:asked, _id, "front"}
  end

  test "an explicit facing overrides the device's role", %{sid: sid} do
    dev = device({:ok, @jpeg})
    start_session(sid, dev)

    assert {:ok, %{facing: "front"}} = Camera.request(sid, facing: "front")
  end

  test "done/1 tells the device that took the photo to release it", %{sid: sid} do
    dev = device({:ok, @jpeg})
    start_session(sid, dev)

    {:ok, %{id: id} = capture} = Camera.request(sid)
    :ok = Camera.done(capture)
    assert_receive {:done, ^id}, 500
  end

  test "no live conversation, or no session at all, is no device", %{sid: sid} do
    assert {:error, :no_device} = Camera.request(sid)
    assert {:error, :no_device} = Camera.request(nil)
  end

  test "a conversation whose bound device is gone is no device", %{sid: sid} do
    gone = spawn(fn -> :ok end)
    ref = Process.monitor(gone)
    assert_receive {:DOWN, ^ref, _, _, _}
    start_session(sid, gone)

    assert {:error, :no_device} = Camera.request(sid)
  end

  test "a device that never answers times out, and is told to let go", %{sid: sid} do
    dev = device(:silent)
    start_session(sid, dev)

    assert {:error, :timeout} = Camera.request(sid, wait_ms: 50)
    assert_received {:asked, id, _facing}
    assert_receive {:done, ^id}, 500
  end

  test "the wait defaults from app env (12 s in production)", %{sid: sid} do
    Application.put_env(:app, :camera_wait_ms, 50)
    on_exit(fn -> Application.delete_env(:app, :camera_wait_ms) end)

    start_session(sid, device(:silent))
    assert {:error, :timeout} = Camera.request(sid)
  end

  test "a device error is handed back as-is", %{sid: sid} do
    start_session(sid, device({:error, {:device, "denied"}}))

    assert {:error, {:device, "denied"}} = Camera.request(sid)
  end

  test "a frame for an unknown or expired id is ignored", %{sid: sid} do
    assert Camera.deliver(Ecto.UUID.generate(), {:ok, @jpeg}) == :ignored

    # expired: the waiter gave up, then the frame lands
    dev = device(:silent)
    start_session(sid, dev)
    assert {:error, :timeout} = Camera.request(sid, wait_ms: 30)
    assert_received {:asked, id, _facing}
    assert Camera.deliver(id, {:ok, @jpeg}) == :ignored
    refute_received {:camera_frame, ^id, _}
  end

  test "the countdown the device shows is 2.4 s" do
    assert Camera.countdown_ms() == 2_400
  end
end
