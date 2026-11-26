# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.FFmpeg.FramerTest do
  use ExUnit.Case, async: true

  alias BB.Camera.FFmpeg.Framer

  # Big enough to be a reference-counted binary, so the copy test below means
  # something: binaries under 64 bytes live on the heap and never pin a parent.
  @frame_bytes 256

  defp frame(byte), do: :binary.copy(<<byte>>, @frame_bytes)

  defp push_all(framer, chunks) do
    Enum.reduce(chunks, {[], framer}, fn chunk, {frames, framer} ->
      {new, framer} = Framer.push(framer, chunk)
      {frames ++ new, framer}
    end)
  end

  defp chunks(bytes, size) do
    for <<chunk::binary-size(^size) <- bytes>>, do: chunk
  end

  test "a read holding exactly one frame produces it" do
    assert {[frame], framer} = Framer.push(Framer.new(@frame_bytes), frame(1))
    assert frame == frame(1)
    assert Framer.buffered(framer) == 0
  end

  test "a frame arriving a byte at a time is reassembled" do
    assert {[frame], _framer} = push_all(Framer.new(@frame_bytes), chunks(frame(7), 1))
    assert frame == frame(7)
  end

  test "several frames in one read come out in order" do
    stream = frame(1) <> frame(2) <> frame(3)

    assert {frames, _framer} = Framer.push(Framer.new(@frame_bytes), stream)
    assert frames == [frame(1), frame(2), frame(3)]
  end

  test "reads that split frames anywhere still frame them exactly" do
    # 5 frames of 256 bytes in reads of 160: reads straddle every boundary.
    stream = Enum.map_join(1..5, &frame/1)

    assert {frames, framer} = push_all(Framer.new(@frame_bytes), chunks(stream, 160))
    assert frames == Enum.map(1..5, &frame/1)
    assert Framer.buffered(framer) == 0
  end

  test "holds no more than one partial frame between reads" do
    {_frames, framer} = Framer.push(Framer.new(@frame_bytes), frame(1) <> frame(2) <> "partial")
    assert Framer.buffered(framer) == byte_size("partial")
  end

  test "frames are copied out rather than pinning the read they arrived in" do
    {[frame, _second], _framer} = Framer.push(Framer.new(@frame_bytes), frame(1) <> frame(2))
    assert :binary.referenced_byte_size(frame) == @frame_bytes
  end
end
