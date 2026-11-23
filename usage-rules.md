<!--
SPDX-FileCopyrightText: 2026 James Harton

SPDX-License-Identifier: Apache-2.0
-->

# BB.Camera.FFmpeg Usage Rules

`bb_camera_ffmpeg` is the ffmpeg capture shared by Beam Bots camera drivers.
It is for writing a camera driver, not for declaring a camera in a robot —
for that, use `bb_camera_v4l` or `bb_camera_avf`. For the camera interface a
driver implements, see `bb_camera`'s rules. This file covers only what is
specific to running a capture.

## Core principles

1. **The driver owns the argument vector.** This package runs whatever it is
   given, as long as it includes `-nostdin` and writes `-f rawvideo` to
   `pipe:1` at a size and pixel format it forces.
2. **One capture per camera.** Start a `BB.Camera.FFmpeg.Capture` when the hub
   asks for capture, stop it when the hub says the last consumer left. Never a
   second one while the first is stopping.
3. **Confirm before delivering.** Wait for `:ready`, tell the hub, then call
   `Capture.go/1`.
4. **`:frame_bytes` must match the arguments.** Compute it from the size and
   pixel format the arguments force (`BB.Camera.Format.frame_size/3`), not
   from what the camera was asked for. A wrong value doesn't fail; it frames
   every frame from the wrong place.
5. **An exit is the only proof the camera is free.** Monitor the capture and
   wait for it to go before starting the next one.

## Wiring it in

```elixir
{:ok, frame_bytes} = BB.Camera.Format.frame_size({:raw, :I420}, 1280, 720)

{:ok, capture} =
  BB.Camera.FFmpeg.Capture.start_link(
    executable: ffmpeg,
    args: [
      "-nostdin", "-f", "v4l2", "-video_size", "1280x720", "-i", "/dev/video0",
      "-vf", "scale=1280:720,format=yuv420p", "-f", "rawvideo", "pipe:1"
    ],
    frame_bytes: frame_bytes,
    sequence_start: state.sequence,
    sink: fn frame -> BB.Camera.Hub.deliver(hub, to_bb_frame(frame)) end
  )

receive do
  {:bb_camera_ffmpeg, ^capture, :ready} ->
    BB.Camera.Hub.capture_started(hub, stream_info)
    BB.Camera.FFmpeg.Capture.go(capture)
end
```

Trap exits in the driver. A capture that fails exits with a reason the
driver should turn into `BB.Error.Hardware.Camera.CaptureFailed`, not into a
crash of its own.

## Exit reasons

| Reason | Meaning |
|---|---|
| `:normal` | Stopped on request; ffmpeg exited |
| `{:shutdown, {:exited, status}}` | ffmpeg exited by itself |
| `{:shutdown, {:no_frames, ms}}` | No frame within `:start_timeout_ms`; ffmpeg stopped |
| `{:shutdown, :teardown_unconfirmed}` | No exit status after a stop; the camera may still be held |
| `{:open_failed, reason}` | The backend could not start |

## Options

| Option | Default | |
|---|---|---|
| `:executable`, `:args` | — | Required |
| `:frame_bytes` | — | Required. The size of one frame of the raw video the arguments produce |
| `:sink` | — | Required. Called inline; a synchronous sink is the delivery bound |
| `:sequence_start` | `0` | Keep counting across restarts; the hub rejects a sequence that goes back |
| `:drop_queue_len` | `8` | Shed frames while more reads than this are waiting |
| `:stdio_window` | 256 KiB | Unacknowledged bytes ffmpeg may have in flight |
| `:start_timeout_ms` | `10000` | Give up when no frame has arrived |
| `:stop_timeout_ms` | `2000` | `SIGTERM` to `SIGKILL` |

## Anti-patterns

- **Leaving out `-nostdin`.** ffmpeg reads the flow-control bytes as commands
  and capture stalls. The backend refuses to start.
- **Starting a replacement before the old capture has exited.** Two ffmpegs
  then contend for one camera, and the second fails in a way that looks like
  broken hardware.
- **Wrapping the sink in a `Task`.** The synchronous sink is what bounds
  delivery.
- **Killing ffmpeg yourself.** MuonTrap is its parent; close the capture
  instead.

## Further reading

- [bb_camera_ffmpeg docs](https://hexdocs.pm/bb_camera_ffmpeg)
- `BB.Camera.FFmpeg.Capture` for the lifecycle, flow control and exit reasons
- `BB.Camera.FFmpeg.Test.StubBackend` for testing a driver without ffmpeg or a
  camera
- [Writing a camera driver](https://hexdocs.pm/bb_camera/01-writing-a-camera-driver.html)
