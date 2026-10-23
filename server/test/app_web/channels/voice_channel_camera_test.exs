defmodule AppWeb.VoiceChannelCameraTest do
  # "Henry, look at this" rides voice:henry (spec 2026-10-23-game-night-design, section 1):
  # the server pushes `camera_capture` to the bound device, the app answers `camera_frame`,
  # and `camera_done` lets it release the frozen snapshot. async: false — the Conversation runs
  # in a supervised process sharing the sandbox.
  use AppWeb.ChannelCase, async: false

  alias App.Camera
  alias App.Conversations.Sessions
  alias App.Users

  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, "a small fake jpeg">>

  setup do
    Application.put_env(:app, :allowed_users, [%{email: "alice@x.com", name: "Alice"}])
    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, alice} = Users.upsert_allowed("alice@x.com")
    {:ok, alice} = Users.update_prefs(alice, %{voice_activation: false})
    %{alice: alice, sid: to_string(alice.id)}
  end

  defp join_voice(user, payload \\ %{}) do
    token = AppWeb.UserAuth.socket_token(user.id)
    {:ok, socket} = connect(AppWeb.UserSocket, %{"token" => token})
    {:ok, _reply, channel} = subscribe_and_join(socket, "voice:#{user.id}", payload)
    on_exit(fn -> Sessions.stop(to_string(user.id)) end)
    channel
  end

  # The look tool's side: ask for a photo from a separate process (it blocks), and hand back
  # the id the device was asked for.
  defp capture(sid, opts \\ []) do
    task = Task.async(fn -> Camera.request(sid, opts) end)
    assert_push "camera_capture", %{id: id, facing: facing, countdown_ms: 2_400}, 1_000
    {task, id, facing}
  end

  test "the bound phone is asked for its back camera; its frame comes back decoded", %{
    alice: alice,
    sid: sid
  } do
    socket = join_voice(alice)
    {task, id, facing} = capture(sid)
    assert facing == "back"

    push(socket, "camera_frame", %{"id" => id, "jpeg" => Base.encode64(@jpeg)})

    assert {:ok, %{id: ^id, jpeg: @jpeg, client: client}} = Task.await(task)
    assert client == socket.channel_pid
  end

  test "a wall is asked for its front camera", %{alice: alice, sid: sid} do
    socket = join_voice(alice, %{"device_id" => "wall", "kiosk" => true})
    {task, id, facing} = capture(sid)
    assert facing == "front"

    push(socket, "camera_frame", %{"id" => id, "jpeg" => Base.encode64(@jpeg)})
    assert {:ok, %{facing: "front"}} = Task.await(task)
  end

  test "the app's own error answer is handed back", %{alice: alice, sid: sid} do
    socket = join_voice(alice)
    {task, id, _facing} = capture(sid)

    push(socket, "camera_frame", %{"id" => id, "error" => "denied"})
    assert {:error, {:device, "denied"}} = Task.await(task)
  end

  test "invalid base64 is a bad frame, and the device is told to let go", %{
    alice: alice,
    sid: sid
  } do
    socket = join_voice(alice)
    {task, id, _facing} = capture(sid)

    push(socket, "camera_frame", %{"id" => id, "jpeg" => "not base64 at all!!"})
    assert {:error, :bad_frame} = Task.await(task)
    assert_push "camera_done", %{id: ^id}
  end

  test "something that decodes but isn't a JPEG is a bad frame", %{alice: alice, sid: sid} do
    socket = join_voice(alice)
    {task, id, _facing} = capture(sid)

    push(socket, "camera_frame", %{"id" => id, "jpeg" => Base.encode64("GIF89a nope")})
    assert {:error, :bad_frame} = Task.await(task)
  end

  test "a frame over 2 MB decoded is refused", %{alice: alice, sid: sid} do
    socket = join_voice(alice)
    {task, id, _facing} = capture(sid)

    big = <<0xFF, 0xD8>> <> :binary.copy(<<0>>, 2 * 1024 * 1024)
    push(socket, "camera_frame", %{"id" => id, "jpeg" => Base.encode64(big)})
    assert {:error, :too_large} = Task.await(task)
  end

  test "a frame for an unknown id is ignored and the channel carries on", %{alice: alice} do
    socket = join_voice(alice)

    push(socket, "camera_frame", %{"id" => Ecto.UUID.generate(), "jpeg" => Base.encode64(@jpeg)})
    push(socket, "camera_frame", %{"id" => "x", "error" => "failed"})
    push(socket, "camera_frame", %{"nonsense" => true})

    # still alive and relaying
    send(socket.channel_pid, {:to_client, :stop_playback})
    assert_push "stop_playback", %{}
  end

  test "camera_done is relayed to the device", %{alice: alice} do
    socket = join_voice(alice)
    send(socket.channel_pid, {:to_client, {:camera_done, "abc"}})
    assert_push "camera_done", %{id: "abc"}
  end

  test "done/1 after the vision call reaches the device that took the photo", %{
    alice: alice,
    sid: sid
  } do
    socket = join_voice(alice)
    {task, id, _facing} = capture(sid)
    push(socket, "camera_frame", %{"id" => id, "jpeg" => Base.encode64(@jpeg)})
    {:ok, capture} = Task.await(task)

    :ok = Camera.done(capture)
    assert_push "camera_done", %{id: ^id}
  end
end
