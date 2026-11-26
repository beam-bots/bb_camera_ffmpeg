# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.FFmpeg.MuonTrapTest do
  @moduledoc """
  The tests that run ffmpeg under MuonTrap for real.

  Everything else stubs the backend, which is right for asserting on behaviour
  but proves nothing about MuonTrap's flow control, its signal handling, or
  whether ffmpeg outlives a capture that died. These run the whole path
  against ffmpeg's synthetic source, so they need ffmpeg but not a camera.

  Tagged `:ffmpeg` and excluded by default. Run them with
  `mix test --include ffmpeg`.
  """
  use ExUnit.Case, async: false

  alias BB.Camera.FFmpeg.Backend
  alias BB.Camera.FFmpeg.Capture

  @moduletag :ffmpeg

  setup do
    case System.find_executable("ffmpeg") do
      nil -> flunk("ffmpeg is not on $PATH")
      ffmpeg -> %{ffmpeg: ffmpeg}
    end
  end

  # A test source at a forced size and pixel format, and the size of one frame
  # of it - the same pair a driver hands `Capture`.
  defp lavfi(width, height, rate) do
    args = [
      "-nostdin",
      "-hide_banner",
      "-loglevel",
      "error",
      "-re",
      "-f",
      "lavfi",
      "-i",
      "testsrc2=size=#{width}x#{height}:rate=#{rate}",
      "-an",
      "-vf",
      "scale=#{width}:#{height},format=yuv420p",
      "-f",
      "rawvideo",
      "-flush_packets",
      "1",
      "pipe:1"
    ]

    {args, div(width * height * 3, 2)}
  end

  defp start_capture(executable, {args, frame_bytes}, opts \\ []) do
    test = self()

    sink = fn frame ->
      send(test, {:frame, frame})
      :ok
    end

    capture =
      start_supervised!(
        {Capture,
         [executable: executable, args: args, frame_bytes: frame_bytes, notify: test, sink: sink] ++
           opts},
        id: :capture,
        restart: :temporary
      )

    :ok = Capture.go(capture)

    capture
  end

  test "captures real raw frames", %{ffmpeg: ffmpeg} do
    capture = start_capture(ffmpeg, lavfi(320, 240, 10))

    # ffmpeg takes a moment to start; the bound is generous because it is an
    # upper bound on an event that must happen, not an estimate.
    assert_receive {:frame, first}, 20_000

    assert byte_size(first.data) == div(320 * 240 * 3, 2)

    assert_receive {:frame, second}, 20_000
    assert second.sequence > first.sequence

    assert Capture.stats(capture).frames >= 2
  end

  test "frames keep coming through a window smaller than one frame", %{ffmpeg: ffmpeg} do
    # Each frame needs many acknowledgements to get through, so this fails if
    # any read goes unacknowledged.
    capture = start_capture(ffmpeg, lavfi(640, 480, 10), stdio_window: 1024)
    frame_bytes = div(640 * 480 * 3, 2)

    for _ <- 1..3 do
      assert_receive {:frame, %{data: data}}, 20_000
      assert byte_size(data) == frame_bytes
    end

    assert Capture.stats(capture).frames >= 3
  end

  test "stopping leaves no ffmpeg behind", %{ffmpeg: ffmpeg} do
    capture = start_capture(ffmpeg, lavfi(160, 120, 10))
    assert_receive {:frame, _frame}, 20_000

    ffmpeg_pid = ffmpeg_pid(capture)

    Process.unlink(capture)
    monitor = Process.monitor(capture)
    :ok = Capture.stop(capture)

    assert_receive {:bb_camera_ffmpeg, ^capture, {:exited, _status}}, 20_000
    assert_receive {:DOWN, ^monitor, :process, ^capture, :normal}

    # MuonTrap reaps ffmpeg before it exits itself, so by the time its exit
    # status has arrived, ffmpeg is gone.
    refute running?(ffmpeg_pid)
  end

  test "killing the capture outright still leaves no ffmpeg behind", %{ffmpeg: ffmpeg} do
    capture = start_capture(ffmpeg, lavfi(160, 120, 10))
    assert_receive {:frame, _frame}, 20_000

    ffmpeg_pid = ffmpeg_pid(capture)
    waiter = watch_process_exit(ffmpeg_pid)

    Process.unlink(capture)
    Process.exit(capture, :kill)

    assert_receive {^waiter, {:exit_status, _status}}, 20_000
    refute running?(ffmpeg_pid)
  end

  test "an ffmpeg that cannot be started fails rather than hanging" do
    capture = start_capture("/nonexistent/ffmpeg", lavfi(160, 120, 10))

    Process.unlink(capture)
    monitor = Process.monitor(capture)

    assert_receive {:bb_camera_ffmpeg, ^capture, {:exited, status}}, 20_000
    assert status != 0
    assert_receive {:DOWN, ^monitor, :process, ^capture, {:shutdown, {:exited, ^status}}}
    refute_received {:frame, _frame}
  end

  test "an argument vector without -nostdin is refused", %{ffmpeg: ffmpeg} do
    {args, _frame_bytes} = lavfi(160, 120, 10)
    args = List.delete(args, "-nostdin")

    assert {:error, :stdin_not_disabled} =
             Backend.MuonTrap.open(ffmpeg, args, stdio_window: 1024, stop_timeout_ms: 500)
  end

  defp ffmpeg_pid(capture) do
    %{handle: port} = :sys.get_state(capture)
    {:os_pid, muontrap_pid} = Port.info(port, :os_pid)
    {output, 0} = System.cmd("pgrep", ["-P", Integer.to_string(muontrap_pid)])

    output |> String.trim() |> String.to_integer()
  end

  defp running?(os_pid) do
    {_output, status} = System.cmd("ps", ["-p", Integer.to_string(os_pid)])

    status == 0
  end

  # A process that is not our child cannot be waited on from the BEAM, so this
  # borrows an event from a program that can wait on it, and a port turns that
  # program's exit into a message. macOS's `caffeinate -w` waits on a kqueue
  # process event; GNU `tail --pid` polls, but in coreutils rather than in the
  # test.
  defp watch_process_exit(os_pid) do
    {program, args} = process_exit_watcher(:os.type(), os_pid)

    case System.find_executable(program) do
      nil ->
        flunk("`#{program}` is needed to observe an OS process exiting")

      executable ->
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          :use_stdio,
          :hide,
          args: args
        ])
    end
  end

  defp process_exit_watcher({:unix, :darwin}, os_pid),
    do: {"caffeinate", ["-w", Integer.to_string(os_pid)]}

  defp process_exit_watcher(_os_type, os_pid),
    do: {"tail", ["--pid=#{os_pid}", "-f", "/dev/null"]}
end
