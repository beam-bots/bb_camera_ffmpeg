# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.FFmpeg.Backend do
  @moduledoc """
  How `BB.Camera.FFmpeg.Capture` talks to the thing producing bytes.

  There is one real implementation — `BB.Camera.FFmpeg.Backend.MuonTrap`,
  ffmpeg running under MuonTrap behind a port — and the behaviour exists so
  capture can also be driven by a stub that produces exactly the bytes a test
  asks for, exactly when the test asks for them.

  That matters more than it might look. Everything interesting about capture is
  a sequence of events: a frame split across three reads, a camera that stops
  sending halfway through one, an ffmpeg that exits with a status nobody
  expected, a consumer falling behind. Against a real camera those are
  arrangeable only by luck. Against a stub each one is a function call.

  ## Message protocol

  A backend delivers to the process that called `c:open/3`, shaped exactly like
  the port messages it stands in for:

      {handle, {:data, binary}}
      {handle, {:exit_status, integer}}

  and, for a backend that links, an exit signal from `handle` when it goes
  away. The handle is opaque: a `t:port/0` for the real backend.

  Every `{:data, binary}` must be acknowledged with `c:ack/2` once it has been
  read. A backend may stop sending until it is.
  """

  @typedoc """
  Opaque reference to a running capture.
  """
  @type handle :: port() | reference() | pid()

  @doc """
  Start `executable` with `args`. Must be called from the process that will
  receive its messages.

  `opts` holds `:stdio_window` and `:stop_timeout_ms` from the capture, merged
  with the capture's `:backend_opts`.
  """
  @callback open(executable :: String.t(), args :: [String.t()], opts :: keyword()) ::
              {:ok, handle()} | {:error, term()}

  @doc """
  Acknowledge `bytes` of output as read, so the backend may send more.
  """
  @callback ack(handle(), bytes :: pos_integer()) :: :ok

  @doc """
  Ask the program to exit. The backend is responsible for making sure it does,
  and reports the exit as `{:exit_status, status}`.
  """
  @callback request_stop(handle()) :: :ok

  @doc """
  Drop the handle without waiting for an exit status.
  """
  @callback close(handle()) :: :ok
end
