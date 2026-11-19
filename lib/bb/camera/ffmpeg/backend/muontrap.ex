# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.FFmpeg.Backend.MuonTrap do
  @moduledoc """
  Runs ffmpeg under MuonTrap, behind an Erlang port.

  MuonTrap is a small C program that starts ffmpeg as its own child and stays
  between it and the BEAM. Three things follow from that, and they are why it
  is here:

  - **ffmpeg cannot outlive its owner.** MuonTrap watches its stdin. When the
    port closes — because its owner crashed, was killed, or the VM halted —
    MuonTrap sends ffmpeg `SIGTERM`, then `SIGKILL` after `:stop_timeout_ms`.
    A bare port gives no such guarantee: the program behind it is reparented
    to init and keeps running until a write fails, and an ffmpeg waiting for
    a camera never writes.
  - **No pid is ever signalled from outside.** MuonTrap is ffmpeg's parent, so
    it reaps it and cannot mistake a recycled pid for it.
  - **Output is flow-controlled.** MuonTrap forwards at most `:stdio_window`
    bytes before they are acknowledged with `ack/2`. That bounds what can
    queue in the reading process's mailbox, which a bare port cannot do.

  ## No shell, ever

  The port is opened with `:spawn_executable` and an explicit argument vector,
  and MuonTrap `execvp`s ffmpeg with the arguments as given. No shell parses
  them.

  ## stdin belongs to MuonTrap

  The acknowledgements travel over MuonTrap's stdin, and ffmpeg inherits it.
  ffmpeg must therefore run with `-nostdin`: without it, ffmpeg reads the
  acknowledgement bytes as keyboard commands — `0x71` is `q` — and takes them
  away from MuonTrap, which then stops forwarding. `open/3` refuses an
  argument vector without it.

  It also means ffmpeg cannot be asked to stop with `q`. `request_stop/1`
  sends MuonTrap `SIGTERM` instead, which passes it to ffmpeg and escalates to
  `SIGKILL` after `:stop_timeout_ms`.

  ## stderr

  ffmpeg's stderr is not captured. It stays attached to the VM's own, so an
  ffmpeg complaint about a busy device or an unsupported format appears on the
  console, where someone setting a camera up will see it.

  ## Exit status

  When ffmpeg exits by itself, MuonTrap exits with its status. When MuonTrap
  is told to stop, it exits `1` whatever ffmpeg did.

  ## A private function

  MuonTrap's public API has no way to stream binary output with flow control:
  `MuonTrap.Daemon` splits output into lines for `Logger`. This module opens
  the port itself and acknowledges through `MuonTrap.Port.report_bytes_handled/2`,
  which MuonTrap does not document. A change to it breaks compilation here,
  not the stream.
  """

  @behaviour BB.Camera.FFmpeg.Backend

  @doc false
  @impl BB.Camera.FFmpeg.Backend
  def open(executable, args, opts) do
    if "-nostdin" in args do
      {:ok,
       Port.open(
         {:spawn_executable, MuonTrap.muontrap_path()},
         port_options(executable, args, opts)
       )}
    else
      {:error, :stdin_not_disabled}
    end
  rescue
    error -> {:error, error}
  end

  @doc false
  @impl BB.Camera.FFmpeg.Backend
  def ack(port, bytes) do
    MuonTrap.Port.report_bytes_handled(port, bytes)
  rescue
    ArgumentError -> :ok
  end

  @doc false
  @impl BB.Camera.FFmpeg.Backend
  def request_stop(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> signal(os_pid)
      nil -> :ok
    end
  end

  @doc false
  @impl BB.Camera.FFmpeg.Backend
  def close(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp port_options(executable, args, opts) do
    muontrap_args =
      [
        "--capture-output",
        "--delay-to-sigkill",
        Integer.to_string(Keyword.fetch!(opts, :stop_timeout_ms)),
        "--stdio-window",
        Integer.to_string(Keyword.fetch!(opts, :stdio_window)),
        "--",
        executable
      ] ++ args

    [:binary, :exit_status, :use_stdio, :hide, args: muontrap_args]
  end

  # The pid names MuonTrap for as long as MuonTrap runs. If it exits between
  # the capture deciding to stop and this signal, the VM has already reaped
  # it, and the number could in principle be reused within that window. The
  # window is the time to spawn `kill`, and reuse needs the pid space to wrap
  # inside it. Without `kill` at all, nothing is signalled; the capture's
  # deadline then closes the port, and MuonTrap ends ffmpeg on its own.
  defp signal(os_pid) do
    case System.find_executable("kill") do
      nil -> :ok
      kill -> System.cmd(kill, ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end

    :ok
  end
end
