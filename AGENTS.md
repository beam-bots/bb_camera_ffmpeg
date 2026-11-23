<!--
SPDX-FileCopyrightText: 2026 James Harton

SPDX-License-Identifier: Apache-2.0
-->

# AGENTS.md

This file provides guidance to AI coding agents when working with code in this
repository.

## Project Overview

`bb_camera_ffmpeg` is the ffmpeg capture shared by Beam Bots camera drivers
(`bb_camera_v4l`, `bb_camera_avf`). It runs an ffmpeg argument vector the
driver supplies, frames the raw video it writes, and hands whole frames to the
driver's sink. It knows nothing about any particular input, and nothing about
`BB.Camera.Hub` beyond the documentation.

It was extracted from `bb_camera_v4l` when `bb_camera_avf` became a second
copy of the same code. A change that only one driver needs belongs in that
driver, in the argument vector or in how it handles capture events.

## Build and Test Commands

```bash
BB_VERSION=local mix check --no-retry        # everything
BB_VERSION=local mix test                    # no ffmpeg needed
BB_VERSION=local mix test --include ffmpeg   # also runs ffmpeg under MuonTrap
```

## Architecture

| Module | |
|---|---|
| `BB.Camera.FFmpeg.Capture` | Owns the backend handle, the framer and the bounds. One per running capture |
| `BB.Camera.FFmpeg.Backend` | How capture gets bytes |
| `BB.Camera.FFmpeg.Backend.MuonTrap` | ffmpeg under MuonTrap, behind a port |
| `BB.Camera.FFmpeg.Framer` | Cuts the stream every `frame_bytes`. A struct, no process |
| `BB.Camera.FFmpeg.FrameRate` | Exact rational frame rates. Pure |

## Things that are easy to get wrong

**MuonTrap is the mechanism, not a nicety.** A bare port leaves the program
behind it running when its owner dies or the VM halts — measured on OTP 29.
ffmpeg usually dies of `SIGPIPE` on its next write, but an ffmpeg waiting for
a camera never writes. ffmpeg's AVFoundation input waits for its first frame
forever, ignoring `q` and `SIGTERM`, and was left running under init by a
halted VM. MuonTrap watches its stdin and kills ffmpeg when the port closes.
There used to be a `Reaper` process doing this from inside the VM; it could
not survive the VM halting, and it had to guess process identity from `/proc`
or `ps`. Do not bring it back.

**ffmpeg must have `-nostdin`.** MuonTrap's acknowledgements travel over its
stdin, which ffmpeg inherits. Without the flag ffmpeg reads them as keyboard
commands (`0x71` is `q`) and steals them from MuonTrap, which then stops
forwarding. `Backend.MuonTrap.open/3` refuses an argument vector without it.

**So there is no `q`.** Stop is `SIGTERM` to MuonTrap, which passes it to
ffmpeg and sends `SIGKILL` after `--delay-to-sigkill` (`:stop_timeout_ms`).
The `kill` is a `System.cmd/3` run inside `Capture`, which traps exits — so
`Capture` must ignore `EXIT`s from ports that are not its handle. Without
that clause it stops `:normal` the moment `kill` finishes, before ffmpeg has.

**Acknowledge every read, including during a stop.** MuonTrap forwards at
most `--stdio-window` bytes unacknowledged, and before it exits it waits up to
ten seconds for every acknowledgement. `Capture` acknowledges each read before
framing it, so the mailbox holds at most one window.

**`MuonTrap.Port.report_bytes_handled/2` is not public API.** It is the only
way to acknowledge without reimplementing MuonTrap's wire format. It is pinned
by `~> 2.0`; a rename breaks compilation, which is the point of calling it
rather than copying it.

**Shedding is by waiting reads, not bytes.** MuonTrap forwards at most 4096
bytes per read on macOS and splices whole pipe buffers on Linux, so one frame
is many reads on a Mac. Measured on macOS: 90 frames at 1280x720 and
1920x1080, 30 fps, shed 1 and 0 with the default `:drop_queue_len` of 8. If
that changes, the signal is wrong, not the threshold.

**Framing is by size, and nothing can resynchronise it.** ffmpeg writes raw
video (`-f rawvideo`): frames end to end, every one `frame_bytes` long, with
no markers and no header. That only works if the stream is exact from its
first byte - which is why the backend leaves ffmpeg's stderr alone rather than
merging it into stdout - and if `frame_bytes` is right. ffmpeg doesn't say on
stdout what it is writing, so the driver forces the output's size and pixel
format in the argument vector (`-vf scale=W:H,format=yuv420p`) and computes
`frame_bytes` from them. There used to be a structural JPEG scanner here; raw
frames made it, and its resynchronisation, unnecessary.

**Capture is confirmed on the first whole frame.** `Capture` holds its first
frame and sends `:ready`; the driver confirms to its hub and then releases it
with `go/1`.

**An exit status is the only proof the camera is free.** `Capture` stays
alive until it arrives. When it does not arrive within `:stop_timeout_ms` plus
a margin, `Capture` exits `{:shutdown, :teardown_unconfirmed}` so the driver
can refuse to open a second ffmpeg against a camera the first may still hold.

**Events are tagged `{:bb_camera_ffmpeg, capture_pid, event}`.** Drivers
match on that.

## Testing

`BB.Camera.FFmpeg.Test.StubBackend` delivers exactly the bytes a test asks
for and reports every acknowledgement, stop request and close to the test.

It lives in `lib`, not `test/support`, against the ecosystem's usual
practice. Every driver built on this package needs it in its own tests, and
a dependency's `test/support` is never compiled; the alternative was a copy
in every driver.

**No test sleeps, and no timed negative assertions.** Timeouts are tested by
making their answer impossible (`start_timeout_ms: 0` with nothing fed) or by
sending the timer's message by hand (`:start_timeout`, `:stop_deadline`). To
show something did not happen, push a call through the process first and use
`refute_received`.

The `:ffmpeg` tests observe ffmpeg's own pid through `pgrep -P` on MuonTrap's,
and wait for it to exit with `caffeinate -w` on macOS or `tail --pid`
elsewhere.

## Dependencies

- `bb` — for units in `FrameRate`
- `muontrap` — the process wrapper

## Licensing headers

Every source file must carry an SPDX header — a `#`-style comment for code, an
HTML comment for Markdown, or a `<file>.license` sidecar for files that can't
hold comments. `mix check` runs `reuse lint` and fails the build if one is
missing.

When you create a new file, its `SPDX-FileCopyrightText` line must credit **the
user you are working for** — not you (the agent), and not this repo's original
author. Take their name from `git config user.name` and use the current year.
