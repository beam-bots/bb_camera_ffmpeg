# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.FFmpeg.Test.StubBackend do
  @moduledoc """
  A capture backend the test drives byte by byte.

  Stands in for ffmpeg under MuonTrap so that every event capture has to cope
  with — a frame split across reads, a truncated image, an unexpected exit
  status, a consumer falling behind — is a function call in the test rather
  than something to wait for and hope for.

  Every operation is synchronous. `feed/2` returns once the data message is in
  the capture's mailbox, so a test can feed bytes and then assert on what came
  out without a sleep anywhere in between.

  It reports what the capture does to it — opening, acknowledging, asking to
  stop, closing — to `:report_to`, which is a pid or a registered name.

  Asked to stop with nobody left to report to - or losing its observer while
  a stop is outstanding - it exits with status `0`, as a well-behaved program
  would. That is the state a test's robot is torn down in, after the test
  process has gone, and a driver that waits for its capture to exit would
  otherwise sit out the full stop deadline.

  It ships in `lib`, not `test/support`, so that camera drivers built on this
  package can declare it as their backend in a test robot. A dependency's
  `test/support` is never compiled. It is for tests only.
  """

  @behaviour BB.Camera.FFmpeg.Backend

  use GenServer

  @doc false
  @impl BB.Camera.FFmpeg.Backend
  def open(executable, args, opts) do
    owner = self()

    case GenServer.start_link(__MODULE__, {executable, args, owner, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @impl BB.Camera.FFmpeg.Backend
  def ack(stub, bytes), do: call_if_alive(stub, {:ack, bytes})

  @doc false
  @impl BB.Camera.FFmpeg.Backend
  def request_stop(stub), do: call_if_alive(stub, :request_stop)

  @doc false
  @impl BB.Camera.FFmpeg.Backend
  def close(stub), do: call_if_alive(stub, :close)

  @doc """
  Deliver `data` to the capture as one read.
  """
  @spec feed(pid(), binary()) :: :ok
  def feed(stub, data), do: GenServer.call(stub, {:feed, data})

  @doc """
  Deliver each binary in turn as a separate read.
  """
  @spec feed_all(pid(), [binary()]) :: :ok
  def feed_all(stub, chunks), do: Enum.each(chunks, &feed(stub, &1))

  @doc """
  Report that the captured process exited with `status`.
  """
  @spec exited(pid(), integer()) :: :ok
  def exited(stub, status), do: GenServer.call(stub, {:exited, status})

  @impl GenServer
  def init({executable, args, owner, opts}) do
    report(opts[:report_to], {:stub_opened, self(), {executable, args, opts}})

    {:ok, %{owner: owner, report_to: opts[:report_to]}}
  end

  @impl GenServer
  def handle_call({:feed, data}, _from, state) do
    send(state.owner, {self(), {:data, data}})

    {:reply, :ok, state}
  end

  def handle_call({:exited, status}, _from, state) do
    send(state.owner, {self(), {:exit_status, status}})

    {:reply, :ok, state}
  end

  def handle_call({:ack, bytes}, _from, state) do
    report(state.report_to, {:stub_acked, self(), bytes})

    {:reply, :ok, state}
  end

  def handle_call(:request_stop, _from, state) do
    case report(state.report_to, {:stub_stop_requested, self()}) do
      {:reported, observer} -> Process.monitor(observer)
      :unobserved -> exit_cleanly(state)
    end

    {:reply, :ok, state}
  end

  def handle_call(:close, _from, state) do
    report(state.report_to, {:stub_closed, self()})

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _monitor, :process, _observer, _reason}, state) do
    exit_cleanly(state)
    {:noreply, state}
  end

  defp exit_cleanly(state), do: send(state.owner, {self(), {:exit_status, 0}})

  defp call_if_alive(stub, message) do
    GenServer.call(stub, message)
  catch
    :exit, _reason -> :ok
  end

  defp report(nil, _message), do: :unobserved

  # A robot's DSL is compiled before the test process exists, so a stub
  # declared in one reports to a registered name rather than a pid.
  defp report(name, message) when is_atom(name) do
    case Process.whereis(name) do
      nil -> :unobserved
      pid -> report(pid, message)
    end
  end

  defp report(pid, message) when is_pid(pid) do
    if Process.alive?(pid) do
      send(pid, message)
      {:reported, pid}
    else
      :unobserved
    end
  end
end
