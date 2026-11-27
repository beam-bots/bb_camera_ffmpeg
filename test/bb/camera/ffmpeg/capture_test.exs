# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.FFmpeg.CaptureTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias BB.Camera.FFmpeg.Capture
  alias BB.Camera.FFmpeg.Test.StubBackend

  @args [
    "-nostdin",
    "-f",
    "lavfi",
    "-i",
    "testsrc2=size=16x8",
    "-f",
    "rawvideo",
    "-pix_fmt",
    "yuv420p",
    "pipe:1"
  ]

  # Big enough to be a reference-counted binary, like a real frame.
  @frame_bytes 256

  # A frame filled with `label`, so a test can tell which one it was handed by
  # matching `%{data: <<label, _::binary>>}`.
  defp raw(label), do: :binary.copy(<<label>>, @frame_bytes)

  # A hub that has already died, as far as a sink calling it can tell.
  defp dead_process do
    pid = spawn(fn -> :ok end)
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}
    pid
  end

  defp sink_to(hub), do: fn frame -> GenServer.call(hub, {:deliver, frame}) end

  defp start_capture(opts \\ []) do
    test = self()

    default_sink = fn frame ->
      send(test, {:frame, frame})
      :ok
    end

    sink = Keyword.get(opts, :sink, default_sink)
    hold? = Keyword.get(opts, :hold, false)

    opts =
      [
        args: @args,
        backend: StubBackend,
        backend_opts: [report_to: test],
        executable: "/usr/bin/ffmpeg",
        frame_bytes: @frame_bytes,
        notify: test,
        sink: sink
      ]
      |> Keyword.merge(Keyword.drop(opts, [:sink, :hold]))

    capture = start_supervised!({Capture, opts}, id: :capture, restart: :temporary)

    assert_receive {:stub_opened, stub, invocation}

    unless hold?, do: Capture.go(capture)

    %{capture: capture, stub: stub, invocation: invocation}
  end

  describe "opening" do
    test "hands the backend the program, its arguments and the flow-control settings" do
      %{invocation: invocation} = start_capture(stdio_window: 4096, stop_timeout_ms: 750)

      assert {"/usr/bin/ffmpeg", @args, opts} = invocation
      assert opts[:stdio_window] == 4096
      assert opts[:stop_timeout_ms] == 750
    end
  end

  describe "framing" do
    test "delivers a whole frame, stamped and numbered" do
      %{stub: stub} = start_capture()

      :ok = StubBackend.feed(stub, raw(1))

      assert_receive {:frame, frame}
      assert frame.data == raw(1)
      assert frame.sequence == 0
      assert is_integer(frame.monotonic_time)
      assert is_integer(frame.wall_time)
    end

    test "reassembles a frame split across reads" do
      %{stub: stub} = start_capture()
      <<first::binary-size(100), second::binary-size(100), third::binary>> = raw(7)

      :ok = StubBackend.feed_all(stub, [first, second, third])

      assert_receive {:frame, frame}
      assert frame.data == raw(7)
    end

    test "numbers frames consecutively" do
      %{stub: stub} = start_capture()

      for index <- 0..3 do
        :ok = StubBackend.feed(stub, raw(index))
        assert_receive {:frame, frame}
        assert frame.sequence == index
      end
    end

    test "starts numbering where a previous capture left off" do
      %{stub: stub} = start_capture(sequence_start: 97)

      :ok = StubBackend.feed(stub, raw(1))

      assert_receive {:frame, frame}
      assert frame.sequence == 97
    end

    test "delivers only the newest frame from a read that held several" do
      %{stub: stub, capture: capture} = start_capture()

      :ok = StubBackend.feed(stub, raw(16) <> raw(32) <> raw(64))

      assert_receive {:bb_camera_ffmpeg, ^capture, {:dropped, 2}}
      assert_receive {:frame, %{data: <<64, _::binary>>}}

      refute_received {:frame, _other}
      assert Capture.stats(capture) == %{frames: 1, dropped: 2}
    end
  end

  describe "confirmation before delivery" do
    test "holds frames until capture has been confirmed" do
      %{stub: stub, capture: capture} = start_capture(hold: true)

      :ok = StubBackend.feed(stub, raw(16))
      assert_receive {:bb_camera_ffmpeg, ^capture, :ready}

      # Pushing a call through proves the read has been handled, so an empty
      # mailbox here means the frame is being held rather than merely late.
      Capture.stats(capture)
      refute_received {:frame, _frame}

      :ok = Capture.go(capture)
      assert_receive {:frame, %{data: <<16, _::binary>>}}
    end

    test "delivers the newest held frame and nothing staler" do
      %{stub: stub, capture: capture} = start_capture(hold: true)

      for label <- [16, 32, 48] do
        :ok = StubBackend.feed(stub, raw(label))
      end

      :ok = Capture.go(capture)

      assert_receive {:frame, %{data: <<48, _::binary>>}}
      refute_received {:frame, _other}
    end
  end

  describe "flow control" do
    test "acknowledges every read with its size" do
      %{stub: stub} = start_capture()
      <<first::binary-size(129), second::binary>> = raw(1)

      :ok = StubBackend.feed_all(stub, [first, second])

      first_size = byte_size(first)
      second_size = byte_size(second)
      assert_receive {:stub_acked, ^stub, ^first_size}
      assert_receive {:stub_acked, ^stub, ^second_size}
    end

    test "acknowledges a read even while the frame in it is held" do
      %{stub: stub} = start_capture(hold: true)

      :ok = StubBackend.feed(stub, raw(1))

      assert_receive {:stub_acked, ^stub, @frame_bytes}
    end

    test "sheds frames while reads are waiting, and resumes after" do
      test = self()

      # Only the first frame holds the capture up; the rest go straight through,
      # so what happens next depends on the backlog and nothing else.
      gate = fn
        %{data: <<16, _::binary>>} = frame ->
          send(test, {:frame, frame})
          receive do: (:release -> :ok)

        frame ->
          send(test, {:frame, frame})
          :ok
      end

      %{stub: stub, capture: capture} = start_capture(sink: gate, drop_queue_len: 1)

      :ok = StubBackend.feed(stub, raw(16))
      assert_receive {:frame, %{data: <<16, _::binary>>}}

      # The capture is blocked inside the sink, so these pile up behind it.
      for label <- [32, 48, 64, 80] do
        :ok = StubBackend.feed(stub, raw(label))
      end

      send(capture, :release)

      assert_receive {:bb_camera_ffmpeg, ^capture, {:dropped, 1}}

      # The last read, with nothing queued behind it, is delivered rather than
      # shed.
      assert_receive {:frame, %{data: <<80, _::binary>>}}
      assert Capture.stats(capture).dropped > 0
    end
  end

  describe "stopping" do
    test "asks the backend to stop, and exits when the program does" do
      %{stub: stub, capture: capture} = start_capture()

      Process.unlink(capture)
      monitor = Process.monitor(capture)

      :ok = Capture.stop(capture)

      assert_receive {:stub_stop_requested, ^stub}
      :ok = StubBackend.exited(stub, 1)

      assert_receive {:bb_camera_ffmpeg, ^capture, {:exited, 1}}
      assert_receive {:DOWN, ^monitor, :process, ^capture, :normal}
    end

    test "keeps acknowledging output while it waits for the exit" do
      %{stub: stub, capture: capture} = start_capture()

      :ok = Capture.stop(capture)
      assert_receive {:stub_stop_requested, ^stub}

      # MuonTrap will not exit with acknowledgements outstanding.
      :ok = StubBackend.feed(stub, raw(1))

      assert_receive {:stub_acked, ^stub, @frame_bytes}
    end

    test "asks only once however often it is told to stop" do
      %{stub: stub, capture: capture} = start_capture()

      :ok = Capture.stop(capture)
      :ok = Capture.stop(capture)
      Capture.stats(capture)

      assert_received {:stub_stop_requested, ^stub}
      refute_received {:stub_stop_requested, ^stub}
    end

    test "says so when the program never confirms its exit" do
      %{stub: stub, capture: capture} = start_capture()

      Process.unlink(capture)
      monitor = Process.monitor(capture)

      :ok = Capture.stop(capture)
      assert_receive {:stub_stop_requested, ^stub}

      # Deliver the deadline now, as if the exit status never came.
      send(capture, :stop_deadline)

      assert_receive {:DOWN, ^monitor, :process, ^capture, {:shutdown, :teardown_unconfirmed}}

      # Closing the port is what makes MuonTrap kill ffmpeg regardless.
      assert_receive {:stub_closed, ^stub}
    end

    test "stop_and_wait returns only once the program has exited" do
      %{stub: stub, capture: capture} = start_capture()

      waiter = Task.async(fn -> Capture.stop_and_wait(capture) end)
      assert_receive {:stub_stop_requested, ^stub}

      # The capture cannot exit before the program does, so the waiter cannot
      # have returned yet.
      assert Task.yield(waiter, 0) == nil

      :ok = StubBackend.exited(stub, 1)

      assert Task.await(waiter) == :ok
      refute Process.alive?(capture)
    end

    test "stop_and_wait returns at once for a capture that has gone" do
      %{capture: capture} = start_capture()
      :ok = stop_supervised(:capture)

      assert Capture.stop_and_wait(capture) == :ok
    end

    test "closes the backend when it is shut down from outside" do
      %{stub: stub, capture: capture} = start_capture()

      :ok = stop_supervised(:capture)

      assert_receive {:stub_closed, ^stub}
      refute Process.alive?(capture)
    end

    test "reports an unexpected exit and stops" do
      %{stub: stub, capture: capture} = start_capture()

      Process.unlink(capture)
      monitor = Process.monitor(capture)

      :ok = StubBackend.exited(stub, 1)

      assert_receive {:bb_camera_ffmpeg, ^capture, {:exited, 1}}
      assert_receive {:DOWN, ^monitor, :process, ^capture, {:shutdown, {:exited, 1}}}
    end

    test "reports a sink that refuses a frame" do
      %{stub: stub, capture: capture} = start_capture(sink: fn _frame -> {:error, :too_stale} end)

      :ok = StubBackend.feed(stub, raw(1))

      assert_receive {:bb_camera_ffmpeg, ^capture, {:sink_error, :too_stale}}
    end
  end

  describe "a sink that exits" do
    test "stops the program and waits for its exit before exiting itself" do
      %{stub: stub, capture: capture} = start_capture(sink: sink_to(dead_process()))

      Process.unlink(capture)
      monitor = Process.monitor(capture)

      :ok = StubBackend.feed(stub, raw(1))
      assert_receive {:stub_stop_requested, ^stub}

      # Still answering, so still waiting for the program rather than gone.
      Capture.stats(capture)
      refute_received {:DOWN, ^monitor, :process, ^capture, _reason}
      refute_received {:stub_closed, ^stub}

      :ok = StubBackend.exited(stub, 0)

      assert_receive {:bb_camera_ffmpeg, ^capture, {:exited, 0}}

      assert_receive {:DOWN, ^monitor, :process, ^capture,
                      {:shutdown, {:sink_exited, {:noproc, _call}}}}
    end

    test "is handed nothing more, and asked to stop only once" do
      test = self()
      hub = dead_process()

      sink = fn frame ->
        send(test, {:frame, frame})
        GenServer.call(hub, {:deliver, frame})
      end

      %{stub: stub, capture: capture} = start_capture(sink: sink)

      :ok = StubBackend.feed(stub, raw(1))
      assert_receive {:frame, %{data: <<1, _::binary>>}}
      assert_receive {:stub_acked, ^stub, @frame_bytes}
      assert_receive {:stub_stop_requested, ^stub}

      :ok = StubBackend.feed(stub, raw(2))
      Capture.stats(capture)

      assert_received {:stub_acked, ^stub, @frame_bytes}
      refute_received {:frame, _frame}
      refute_received {:stub_stop_requested, ^stub}
    end

    test "says so when the program never confirms its exit" do
      %{stub: stub, capture: capture} = start_capture(sink: sink_to(dead_process()))

      Process.unlink(capture)
      monitor = Process.monitor(capture)

      :ok = StubBackend.feed(stub, raw(1))
      assert_receive {:stub_stop_requested, ^stub}

      send(capture, :stop_deadline)

      assert_receive {:DOWN, ^monitor, :process, ^capture, {:shutdown, :teardown_unconfirmed}}
      assert_receive {:stub_closed, ^stub}
    end
  end

  describe "start timeout" do
    test "stops a program that never produces a first frame" do
      # Nothing is ever fed, so the timeout fires because a frame cannot come,
      # not because one was late.
      %{stub: stub, capture: capture} = start_capture(start_timeout_ms: 0)

      Process.unlink(capture)
      monitor = Process.monitor(capture)

      assert_receive {:bb_camera_ffmpeg, ^capture, {:no_frames, 0}}
      assert_receive {:stub_stop_requested, ^stub}

      :ok = StubBackend.exited(stub, 1)

      assert_receive {:DOWN, ^monitor, :process, ^capture, {:shutdown, {:no_frames, 0}}}
    end

    test "is disarmed by a first frame" do
      %{stub: stub, capture: capture} = start_capture()

      :ok = StubBackend.feed(stub, raw(1))
      assert_receive {:frame, _frame}

      # Deliver the timer's message now rather than waiting for it.
      send(capture, :start_timeout)
      Capture.stats(capture)

      refute_received {:bb_camera_ffmpeg, ^capture, {:no_frames, _timeout}}
      refute_received {:stub_stop_requested, ^stub}
    end

    test "does not interrupt a stop already in progress" do
      %{stub: stub, capture: capture} = start_capture()

      :ok = Capture.stop(capture)
      assert_receive {:stub_stop_requested, ^stub}

      send(capture, :start_timeout)
      Capture.stats(capture)

      refute_received {:bb_camera_ffmpeg, ^capture, {:no_frames, _timeout}}
    end
  end
end
