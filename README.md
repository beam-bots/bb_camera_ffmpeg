<!--
SPDX-FileCopyrightText: 2026 James Harton

SPDX-License-Identifier: Apache-2.0
-->

<img src="https://github.com/beam-bots/bb/blob/main/logos/beam_bots_logo.png?raw=true" alt="Beam Bots Logo" width="250" />

# bb_camera_ffmpeg

[![CI](https://github.com/beam-bots/bb_camera_ffmpeg/actions/workflows/ci.yml/badge.svg)](https://github.com/beam-bots/bb_camera_ffmpeg/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache--2.0-green.svg)](https://opensource.org/licenses/Apache-2.0)
[![Hex version badge](https://img.shields.io/hexpm/v/bb_camera_ffmpeg.svg)](https://hex.pm/packages/bb_camera_ffmpeg)
[![Hexdocs badge](https://img.shields.io/badge/docs-hexdocs-purple)](https://hexdocs.pm/bb_camera_ffmpeg)
[![REUSE status](https://api.reuse.software/badge/github.com/beam-bots/bb_camera_ffmpeg)](https://api.reuse.software/info/github.com/beam-bots/bb_camera_ffmpeg)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/beam-bots/bb_camera_ffmpeg)

The ffmpeg capture that [Beam Bots](https://github.com/beam-bots/bb) camera
drivers share: an ffmpeg process that cannot outlive its owner, flow-controlled
output, and framing of the raw video it writes.

You do not use this package directly in a robot. A camera driver uses it:

- [`bb_camera_v4l`](https://github.com/beam-bots/bb_camera_v4l) for Linux V4L2
  devices.
- [`bb_camera_avf`](https://github.com/beam-bots/bb_camera_avf) for macOS
  cameras through AVFoundation.

Each driver builds the ffmpeg argument vector for its own input, decoding
whatever the device produces into raw video at a size and pixel format it
forces. This package runs it, frames the output, and hands whole raw frames to
the driver.

## What it does

```
MuonTrap ──> ffmpeg ──pipe──> Capture ──frames──> the driver's sink
   ▲                             │
   └──── acknowledgements ───────┘
```

- **`BB.Camera.FFmpeg.Capture`** — one process per running capture. It holds
  the first frame until the driver confirms capture, sheds frames when it
  falls behind, stops an ffmpeg that never produces a frame, and confirms the
  exit before it goes.
- **`BB.Camera.FFmpeg.Backend.MuonTrap`** — runs ffmpeg under
  [MuonTrap](https://hex.pm/packages/muontrap). MuonTrap kills ffmpeg when the
  port closes for any reason, including the VM halting, and forwards output
  only as fast as it is acknowledged.
- **`BB.Camera.FFmpeg.Framer`** — cuts the byte stream into frames of the
  fixed size the driver says one frame takes.
- **`BB.Camera.FFmpeg.FrameRate`** — exact rational frame rates, so
  `30000/1001` is not rounded to a different rate on its way to ffmpeg.

## Requirements

- **ffmpeg** on the target.
- **A C compiler at build time**, for MuonTrap's wrapper program. Nerves
  toolchains have one; on macOS it means the Xcode command line tools.

## Installation

```elixir
def deps do
  [
    {:bb_camera_ffmpeg, "~> 0.1"}
  ]
end
```

## Limitations

- **Raw video only.** ffmpeg must write `-f rawvideo` to `pipe:1`, at a size
  and pixel format the arguments force
  (`-vf scale=W:H:out_range=full,format=yuv420p -fps_mode passthrough`), and
  the driver must say how many bytes one frame takes. Raw video carries no
  description of itself, and nothing else reads ffmpeg's stdout, so there is
  nothing to resynchronise on if either is wrong.
- **ffmpeg must run with `-nostdin`.** MuonTrap's flow control uses stdin, and
  ffmpeg inherits it. Without the flag, ffmpeg reads the acknowledgements as
  keyboard commands. The backend refuses to start without it.
- **Timestamps are arrival times**, not exposure times. A raw video stream
  carries none of its own.
- **It calls a function MuonTrap does not document**,
  `MuonTrap.Port.report_bytes_handled/2`, because MuonTrap's public API has no
  binary streaming with flow control. A change there breaks compilation here.

## Testing

```sh
BB_VERSION=local mix test                   # no ffmpeg needed
BB_VERSION=local mix test --include ffmpeg  # also runs ffmpeg under MuonTrap
BB_VERSION=local mix check --no-retry
```

The default suite drives capture through a stub backend, so every case is a
function call rather than something to wait for. The `:ffmpeg` tests run real
ffmpeg against its synthetic `testsrc2` source and check that nothing outlives
a stopped or killed capture.

## Licence

Apache-2.0. See `LICENSES/`.
