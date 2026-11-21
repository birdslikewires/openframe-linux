# openframe-crystalhd

Support for the Broadcom Crystal HD video decoders (BCM70012 and BCM70015, mini PCIe cards) on the
OpenFrame 2. The package isn't part of the image; units with a card install it with
`sudo apt install openframe-crystalhd`. The kernel driver it needs, `crystalhd`, comes with the
OpenFrame kernel ([openframe-kernel](https://github.com/birdslikewires/openframe-kernel)'s
`crystalhd/`) and loads by itself when the card is fitted.

It holds:

- **libcrystalhd** 3.6, from [birdslikewires/crystalhd](https://github.com/birdslikewires/crystalhd),
  which is [twopoint71/crystalhd](https://github.com/twopoint71/crystalhd) with our fixes. They fix
  the random stall on the BCM70015:
  - twopoint71's commit d8ad111 asked the driver for its free input space with bit 31 clear, so the
    library sized each send by its own 1 MB ring instead of the card's 768 KB buffer. The card
    refused every oversized send, and the library retried it for ever.
  - A lock is now released on an error path, where it otherwise hung the next send.
  - Sends are whole dwords until the end of the stream, as the driver refuses unaligned addresses
    for good.
- **The firmware**, `bcm70015fw.bin` and `bcm70012fw.bin`, in `/usr/lib/firmware`, where the
  library loads it from. Broadcom's licence allows redistribution of the unmodified files with its
  notice, which is in the package's `copyright`. The build checks the files are byte for byte the
  ones Debian shipped in `firmware-crystalhd`.
- **chdplay** (`chdplay.cpp`, MIT like the rest of this repository), a player. FFmpeg dropped its
  Crystal HD decoders in 2024, so it uses FFmpeg only to read files and streams and to decode the
  sound. The card decodes the H.264 video and scales it to the panel width. Files, HTTPS and HLS
  play, with the sound as the clock.

```
sudo chdplay [--audio URL] [--buffer S] [--scale W|0] [--fps N] [--bench] [--noaudio]
             [--timeout S] [--lead S] [--maxtemp C] file|URL
```

For streams:

- Each input is read on its own thread, and network inputs reconnect when the server drops them.
- When an input runs dry, playback pauses until it has `--buffer` seconds in hand (default 2,
  doubling after each stall up to 8). It doesn't drop everything that arrives late. The sound
  resumes on the sample where it stopped.
- `--audio URL` takes the sound from a second input, for sources that keep video and audio
  apart. YouTube has no 1080p60 stream with sound built in, for example:

  ```
  sudo chdplay --audio "$(yt-dlp -g -f 140 URL)" "$(yt-dlp -g -f 299 URL)"
  ```

  Format 299 is 1080p60 H.264 and 140 is AAC. The card can't decode VP9 or AV1.
- Pictures are timed from the stream's timestamps, so streams with gaps and changing frame rates
  stay in sync.

`--maxtemp` (default 88) stops playback if the chip's own sensor passes that many degrees. A bare
card under 1080p at 60 frames a second heats by about a degree a second. With a thermal pad onto
the OpenFrame 2's metal back, it settles at about 68 °C after hours of 1080p60.

## Building

`.github/workflows/crystalhd.yml` builds the package on every push that changes this folder or the
workflow, tests it on a clean Trixie, and publishes it to the same apt repository as
`openframe-scripts`. `build.sh` does the build in an i386 Debian Trixie container:

```
docker run --rm --security-opt seccomp=unconfined --platform linux/386 \
  -v "$PWD/crystalhd:/src:ro" -v "$PWD/out:/out" i386/debian:trixie sh /src/build.sh /src 26.11.1 /out
```

The version is year.month.N, counted by `version.sh` like `openframe-scripts`. The library comes from
a fixed commit, `COMMIT` in `build.sh`: to take changes, commit them to birdslikewires/crystalhd, push,
and change `COMMIT` here. On an x86 Linux host the container needs `--security-opt seccomp=unconfined`
as above, or Docker's default filter stops the i386 apt resolving names.

The dependencies are Debian's FFmpeg, ALSA and libdrm libraries: about 155 MB on a fresh system,
which fits the OpenFrame 2's 2 GB internal memory.
