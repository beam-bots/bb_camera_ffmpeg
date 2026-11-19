# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.FFmpeg.FrameRateTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias BB.Camera.FFmpeg.FrameRate

  doctest BB.Camera.FFmpeg.FrameRate

  test "a rational rate is not rounded on the way through" do
    rate = FrameRate.new!({30_000, 1001})

    assert FrameRate.to_string(rate) == "30000/1001"
    assert_in_delta FrameRate.to_float(rate), 29.97, 0.001
  end

  test "a decimal rate becomes the exact rational that was written" do
    assert FrameRate.new!(29.97) == %FrameRate{numerator: 2997, denominator: 100}
    assert FrameRate.new!(7.5) == %FrameRate{numerator: 15, denominator: 2}
  end

  test "reduces to lowest terms" do
    assert FrameRate.new!({60, 2}) == %FrameRate{numerator: 30, denominator: 1}
  end

  test "accepts a hertz unit" do
    import BB.Unit

    assert FrameRate.new!(~u(15 hertz)) == %FrameRate{numerator: 15, denominator: 1}
  end
end
