# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.FFmpeg.Capture do
  @moduledoc """
  One running capture: the ffmpeg process, the framer, and the bounds.

  A camera driver starts one of these when its hub asks for capture and stops
  it when the hub says the last consumer has gone. Consumers never reach it —
  they talk to `BB.Camera.Hub`, which refcounts them, so two browser tabs on
  the same camera produce one of these, not two.

  It is a process of its own rather than part of the driver so that the driver
  stays answerable while a frame delivery is in flight. `BB.Camera.Hub.deliver/2`
  is a synchronous call by design, and a driver blocked inside one would not be
  reading the message asking it to stop.

  The driver supplies the ffmpeg argument vector; this module neither knows nor
  cares which input it names. It must include `-nostdin` and write raw video
  (`-f rawvideo`) to `pipe:1` — see `BB.Camera.FFmpeg.Backend.MuonTrap`. Raw
  video doesn't describe itself, so the argument vector must also force the
  output's size and pixel format, and `:frame_bytes` must be what one frame of
  that takes; see `BB.Camera.FFmpeg.Framer`.

  ## Bounding ingress

  ffmpeg runs under MuonTrap, which forwards at most `:stdio_window` bytes of
  output before this process acknowledges them. Each read is acknowledged as it
  is taken from the mailbox, so the mailbox never holds more than one window,
  however fast ffmpeg writes and however slowly this process is scheduled. When
  this process falls a whole window behind, ffmpeg blocks on its write and the
  backlog stays outside the VM.

  Within that bound, frames are **shed** rather than delivered while more than
  `:drop_queue_len` reads are waiting: the hub keeps only the newest frame, so
  a frame that would be superseded before anyone could see it is not worth a
  blocking call. The queue drains while frames are shed, and delivery resumes
  below the threshold. Within a single read, likewise, only the newest frame is
  delivered.

  The framer holds at most one partial frame, so memory held here is at most
  one window plus one frame.

  ## Confirming capture

  ffmpeg starting says only that ffmpeg exists. The first whole frame is the
  evidence that the camera opened, so it is held, the owner is sent `:ready`,
  and nothing reaches the sink until the owner calls `go/1`.

  An ffmpeg that never produces a first frame is stopped after
  `:start_timeout_ms`, and the capture exits `{:shutdown, {:no_frames, ms}}`.
  Some inputs wait for a first frame forever: ffmpeg's AVFoundation input does
  when macOS withholds camera access, and ignores `SIGTERM` while it waits.

  ## Stopping

  `stop/1` asks MuonTrap to stop ffmpeg, which escalates to `SIGKILL` after
  `:stop_timeout_ms`. The capture stays alive until the exit status arrives,
  because whatever starts the next capture needs the camera released first.
  If no exit status arrives even after that, it closes the port, which makes
  MuonTrap kill ffmpeg, and exits `{:shutdown, :teardown_unconfirmed}` so the
  owner knows the camera may still be held.

  A sink that exits - a hub that died while a frame was on its way to it - is
  stopped the same way. Nothing more is handed to the sink, and once the exit
  status arrives the capture exits `{:shutdown, {:sink_exited, reason}}`, or
  `{:shutdown, :teardown_unconfirmed}` if it never does.

  ## Timestamps, honestly

  A frame is stamped when the read that completed it arrived in this process.
  That is **not** the moment the sensor was exposed. Between the two sit the
  camera's own pipeline, the OS's capture buffers, ffmpeg, MuonTrap, the pipe,
  and the BEAM's scheduler.

  Nothing better is available on this path: the raw video ffmpeg writes is a
  bare concatenation of frames with no container and therefore no timestamps
  at all. The stamps are monotonic and in arrival order, so inter-frame
  intervals are meaningful even though absolute times are offset.
  """

  use GenServer

  alias BB.Camera.FFmpeg.Framer

  require Logger

  @default_drop_queue_len 8
  @default_start_timeout_ms 10_000
  @default_stdio_window 256 * 1024
  @default_stop_timeout_ms 2_000

  # MuonTrap sends SIGKILL at `stop_timeout_ms`. This is the time on top of
  # that for the kill, MuonTrap's own exit and the port's exit message, before
  # the teardown is called unconfirmed.
  @teardown_margin_ms 1_000

  @typedoc """
  One frame, as handed to the sink.

  Only what this module knows: the bytes, and when and in what order they
  arrived. Format and dimensions are the driver's, since the driver forced
  them.
  """
  @type frame :: %{
          data: binary(),
          sequence: non_neg_integer(),
          monotonic_time: integer(),
          wall_time: integer()
        }

  @typedoc """
  What capture tells its owner about, beyond the frames themselves.
  """
  @type event ::
          {:exited, status :: integer()}
          | {:dropped, frames :: pos_integer()}
          | {:sink_error, term()}
          | :ready
          | {:no_frames, timeout_ms :: pos_integer()}

  @doc """
  Start a capture.

  ## Options

  - `:executable` — path to ffmpeg. Required.
  - `:args` — ffmpeg's arguments, including `-nostdin`. Required.
  - `:frame_bytes` — the size of one frame of the raw video the arguments
    produce. Required.
  - `:sink` — a 1-arity function called with each `t:frame/0`, returning
    `:ok` or `{:error, reason}`. Called inline, so a synchronous sink is what
    bounds delivery. A sink that exits stops the capture. Required.
  - `:notify` — process to send `t:event/0`s to, tagged
    `{:bb_camera_ffmpeg, capture_pid, event}`. Default the starting process.
  - `:sequence_start` — first sequence number. A camera that restarts its
    capture must keep counting up, because the hub rejects a sequence that does
    not strictly increase. Default `0`.
  - `:drop_queue_len` — shed frames while more reads than this are waiting.
    Default #{@default_drop_queue_len}.
  - `:stdio_window` — bytes of output ffmpeg may have in flight before this
    process acknowledges them. Default #{@default_stdio_window}.
  - `:start_timeout_ms` — how long to wait for the first whole frame. Default
    #{@default_start_timeout_ms}, which leaves time to answer an OS
    permission prompt.
  - `:stop_timeout_ms` — how long ffmpeg gets to exit on `SIGTERM` before it
    is sent `SIGKILL`. Default #{@default_stop_timeout_ms}.
  - `:backend`, `:backend_opts` — defaults `BB.Camera.FFmpeg.Backend.MuonTrap`
    and `[]`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, Keyword.put_new(opts, :notify, self()))

  @doc """
  Stop the capture, giving ffmpeg a chance to release the camera first.

  Asynchronous, because the caller is the driver and the driver has a hub
  waiting to be told that capture has ended. `Process.monitor/1` the capture
  first when you need to know it has finished.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(capture) do
    GenServer.cast(capture, :stop)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Let frames start flowing to the sink.

  A capture holds its frames until this is called, so that the hub cannot be
  handed a frame before the driver has confirmed to it that capture started —
  it would refuse one, and the frame would be lost for no reason.

  Nothing is dropped in the meantime beyond what the newest-frame-wins policy
  would have dropped anyway: the most recent frame is held and delivered here.
  """
  @spec go(GenServer.server()) :: :ok
  def go(capture) do
    GenServer.cast(capture, :go)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Counters for this capture: frames delivered and frames shed.
  """
  @spec stats(GenServer.server()) :: map()
  def stats(capture), do: GenServer.call(capture, :stats)

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    backend = Keyword.get(opts, :backend, BB.Camera.FFmpeg.Backend.MuonTrap)
    stop_timeout_ms = Keyword.get(opts, :stop_timeout_ms, @default_stop_timeout_ms)

    backend_opts =
      Keyword.merge(
        [
          stdio_window: Keyword.get(opts, :stdio_window, @default_stdio_window),
          stop_timeout_ms: stop_timeout_ms
        ],
        Keyword.get(opts, :backend_opts, [])
      )

    case backend.open(
           Keyword.fetch!(opts, :executable),
           Keyword.fetch!(opts, :args),
           backend_opts
         ) do
      {:ok, handle} ->
        start_timeout_ms = Keyword.get(opts, :start_timeout_ms, @default_start_timeout_ms)
        Process.send_after(self(), :start_timeout, start_timeout_ms)

        {:ok,
         %{
           backend: backend,
           drop_queue_len: Keyword.get(opts, :drop_queue_len, @default_drop_queue_len),
           failure: nil,
           framer: Framer.new(Keyword.fetch!(opts, :frame_bytes)),
           handle: handle,
           notify: Keyword.fetch!(opts, :notify),
           pending: nil,
           sequence: Keyword.get(opts, :sequence_start, 0),
           sink: Keyword.fetch!(opts, :sink),
           start_timeout_ms: start_timeout_ms,
           started: false,
           stats: %{frames: 0, dropped: 0},
           stop_timeout_ms: stop_timeout_ms,
           stopping: false
         }}

      {:error, reason} ->
        {:stop, {:open_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call(:stats, _from, state), do: {:reply, state.stats, state}

  @impl GenServer
  def handle_cast(:go, %{started: true} = state), do: {:noreply, state}

  def handle_cast(:go, %{pending: nil} = state), do: {:noreply, %{state | started: true}}

  def handle_cast(:go, state) do
    {frame, monotonic_time, wall_time} = state.pending

    {:noreply, deliver(%{state | started: true, pending: nil}, frame, monotonic_time, wall_time)}
  end

  def handle_cast(:stop, %{stopping: true} = state), do: {:noreply, state}
  def handle_cast(:stop, state), do: {:noreply, begin_stop(state)}

  @impl GenServer
  def handle_info({handle, {:data, chunk}}, %{handle: handle} = state) do
    # Acknowledged before anything else: MuonTrap waits for every byte to be
    # acknowledged before it exits, including during a stop.
    state.backend.ack(handle, byte_size(chunk))

    {:noreply, read(state, chunk, message_queue_len())}
  end

  def handle_info({handle, {:exit_status, status}}, %{handle: handle} = state) do
    notify(state, {:exited, status})

    state = %{state | handle: nil}

    cond do
      state.failure -> {:stop, {:shutdown, state.failure}, state}
      state.stopping -> {:stop, :normal, state}
      true -> {:stop, {:shutdown, {:exited, status}}, state}
    end
  end

  def handle_info(:start_timeout, %{stopping: true} = state), do: {:noreply, state}

  def handle_info(:start_timeout, state) do
    if framed?(state) do
      {:noreply, state}
    else
      notify(state, {:no_frames, state.start_timeout_ms})

      {:noreply, begin_stop(%{state | failure: {:no_frames, state.start_timeout_ms}})}
    end
  end

  def handle_info(:stop_deadline, state) do
    Logger.error(
      "ffmpeg did not exit within #{state.stop_timeout_ms + @teardown_margin_ms}ms of being asked to stop"
    )

    {:stop, {:shutdown, :teardown_unconfirmed}, state}
  end

  def handle_info({:EXIT, handle, _reason}, %{handle: handle} = state),
    do: {:noreply, state}

  # Any other port is one the backend opened in this process for a moment -
  # the `kill` behind a stop request - and its exit says nothing about the
  # capture.
  def handle_info({:EXIT, port, _reason}, state) when is_port(port), do: {:noreply, state}

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{handle: nil}), do: :ok

  # Closing the port is what makes MuonTrap end ffmpeg, whatever brought this
  # process down.
  def terminate(_reason, state), do: state.backend.close(state.handle)

  defp begin_stop(state) do
    state.backend.request_stop(state.handle)
    Process.send_after(self(), :stop_deadline, state.stop_timeout_ms + @teardown_margin_ms)

    %{state | stopping: true}
  end

  defp read(state, chunk, queue_len) do
    monotonic_time = System.monotonic_time(:nanosecond)
    wall_time = System.system_time(:nanosecond)

    {frames, framer} = Framer.push(state.framer, chunk)

    handle_frames(%{state | framer: framer}, frames, queue_len, monotonic_time, wall_time)
  end

  defp handle_frames(state, [], _queue_len, _monotonic_time, _wall_time), do: state

  defp handle_frames(state, frames, queue_len, monotonic_time, wall_time) do
    if queue_len > state.drop_queue_len do
      shed(state, frames)
    else
      # Everything but the newest frame in this read would be overwritten in
      # the hub before a consumer could ask for it.
      {superseded, [newest]} = Enum.split(frames, length(frames) - 1)

      state
      |> shed(superseded)
      |> take(newest, monotonic_time, wall_time)
    end
  end

  defp take(%{started: true} = state, frame, monotonic_time, wall_time),
    do: deliver(state, frame, monotonic_time, wall_time)

  defp take(state, frame, monotonic_time, wall_time) do
    if state.pending do
      notify(state, {:dropped, 1})
    else
      notify(state, :ready)
    end

    %{state | pending: {frame, monotonic_time, wall_time}}
  end

  defp shed(state, []), do: state

  defp shed(state, frames) do
    count = length(frames)
    notify(state, {:dropped, count})

    update_in(state.stats.dropped, &(&1 + count))
  end

  defp deliver(%{failure: {:sink_exited, _reason}} = state, _data, _monotonic_time, _wall_time),
    do: state

  defp deliver(state, data, monotonic_time, wall_time) do
    frame = %{
      data: data,
      sequence: state.sequence,
      monotonic_time: monotonic_time,
      wall_time: wall_time
    }

    case call_sink(state.sink, frame) do
      :ok ->
        delivered(state)

      {:error, reason} ->
        notify(state, {:sink_error, reason})
        delivered(state)

      {:sink_exited, reason} ->
        sink_exited(state, reason)
    end
  end

  # The sink is normally a synchronous call to a hub, and a hub can die. Left
  # to crash, this process would close its port and leave the program to be
  # killed after it had gone, with nothing waiting for the camera to be free -
  # and a restarted driver would race the old program for the device.
  defp call_sink(sink, frame) do
    sink.(frame)
  catch
    :exit, reason -> {:sink_exited, reason}
  end

  defp delivered(state) do
    state
    |> Map.put(:sequence, state.sequence + 1)
    |> update_in([:stats, :frames], &(&1 + 1))
  end

  defp sink_exited(%{stopping: true} = state, reason),
    do: %{state | failure: {:sink_exited, reason}}

  defp sink_exited(state, reason), do: begin_stop(%{state | failure: {:sink_exited, reason}})

  # Shed frames count: they prove ffmpeg is producing just as well as
  # delivered ones do.
  defp framed?(state),
    do: state.pending != nil or state.stats.frames > 0 or state.stats.dropped > 0

  defp notify(state, event), do: send(state.notify, {:bb_camera_ffmpeg, self(), event})

  defp message_queue_len do
    {:message_queue_len, length} = Process.info(self(), :message_queue_len)

    length
  end
end
