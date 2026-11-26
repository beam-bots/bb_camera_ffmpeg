# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.FFmpeg.Framer do
  @moduledoc """
  Turns the byte stream coming out of a capture into whole raw frames.

  ffmpeg writing `-f rawvideo` produces frames end to end with nothing between
  them, every one exactly `frame_bytes` long. A pipe hands over whatever
  happened to be readable, so a frame arrives across several reads and a read
  routinely holds the tail of one frame and the head of the next. The framer
  owns that buffer and cuts it every `frame_bytes`.

  It is a plain struct with no process of its own, so it can be driven straight
  from a test with a list of byte chunks.

  ## No resynchronisation

  Raw video has no markers, so there is nothing to resynchronise on: the framer
  relies on the stream being exact from its first byte, and a pipe from a
  single writer is. That only holds if nothing else writes to ffmpeg's stdout,
  which is why `BB.Camera.FFmpeg.Backend.MuonTrap` leaves its stderr alone.

  It also relies on `frame_bytes` being right. ffmpeg doesn't say what it is
  writing on stdout, so the driver has to make it so: force the output's size
  and pixel format in the argument vector, and compute `frame_bytes` from them.

  ## Bounds

  The buffer never holds more than one partial frame plus whatever one read
  delivered, regardless of what the stream does.

  Note that this bounds the *framer*. The mailbox of the process reading the
  capture is bounded separately, by the flow-control window described in
  `BB.Camera.FFmpeg.Capture`.
  """

  defstruct buffer: <<>>, frame_bytes: nil

  @type t :: %__MODULE__{buffer: binary(), frame_bytes: pos_integer()}

  @doc """
  Build a framer for frames of exactly `frame_bytes` bytes.
  """
  @spec new(pos_integer()) :: t()
  def new(frame_bytes) when is_integer(frame_bytes) and frame_bytes > 0,
    do: %__MODULE__{frame_bytes: frame_bytes}

  @doc """
  Append `bytes` to the buffer and cut off whatever whole frames that completes.

  Returns the frames in arrival order, and the framer to use for the next read.
  """
  @spec push(t(), binary()) :: {[binary()], t()}
  def push(%__MODULE__{} = framer, bytes) do
    buffer = framer.buffer <> bytes
    count = div(byte_size(buffer), framer.frame_bytes)
    consumed = count * framer.frame_bytes

    # Each frame is a sub-binary of the accumulated buffer, which also holds the
    # bytes of every other frame in this read. Downstream keeps the latest frame
    # for as long as a consumer is slow, so copying is what stops one frame
    # pinning a whole read's worth of bytes.
    frames =
      for index <- 0..(count - 1)//1,
          do: :binary.copy(:binary.part(buffer, index * framer.frame_bytes, framer.frame_bytes))

    rest = :binary.part(buffer, consumed, byte_size(buffer) - consumed)

    {frames, %{framer | buffer: :binary.copy(rest)}}
  end

  @doc """
  How many bytes the framer is holding on to.
  """
  @spec buffered(t()) :: non_neg_integer()
  def buffered(%__MODULE__{buffer: buffer}), do: byte_size(buffer)
end
