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
- **chdplay** (`chdplay.cpp`), a player. FFmpeg dropped its Crystal HD decoders in 2024, so it uses
  FFmpeg only to read files and streams and to decode the sound. The card decodes the H.264 video
  and scales it to the panel width. Files, HTTPS and HLS play, with the sound as the clock.

```
sudo chdplay [--scale W|0] [--fps N] [--bench] [--noaudio] [--timeout S] [--lead S]
             [--maxtemp C] file|URL
```

`--maxtemp` (default 88) stops playback if the chip's own sensor passes that many degrees. There's no
heatsink on the card, and 1080p at 60 frames a second heats the BCM70015 by about a degree a second;
24 and 30 frames a second settle at about 66–74 °C.

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
