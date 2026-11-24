# openframe-resampler

ALSA's `openframe` rate converter. When something plays at a rate the OpenFrame's mixer isn't
at (a 48 kHz video into the 44.1 kHz mixer, say), ALSA's `plug` resamples it. Its own converter
is linear interpolation, with no filter, which leaves false tones in the treble: a 15 kHz tone
gets a false one only 13 dB below it, and a 23 kHz tone (above what 44.1 kHz can carry) folds
back down at -7 dB. `openframe` is the Speex resampler at quality 5, which keeps both 80 dB down
or more and is flat to about 20 kHz.

`of-audio` (openframe-scripts, which depends on this package) names it in `/etc/asound.conf`
wherever it's installed. Direct to DAC passes the audio as it is, so it's only used there for a
rate the DAC can't take at all.

## What's different from Debian's

Debian's `libasound2-plugins` has a `speexrate` converter, but on i386 it brings in about 100
packages (ffmpeg, PulseAudio, JACK and more), and its libspeexdsp is built for the i386 baseline,
without SSE. This package is one 26 KB file:

- **SSE2.** speexdsp's `resample.c` (from Debian's source package, checked by its md5) is built
  into the plugin with its SSE and SSE2 inner loops. Every OpenFrame's Atom (Z5xx) has SSE3.
- **The direct table** (`resample-direct.patch`). Speex works out the filter for each sample
  by interpolation unless a table of it would be no bigger, which on the Atom costs twice the
  time. The patch takes the table whenever it's 4 MB or less.
- **A small table.** The rate plugin gives Speex the ratio of the two sides' periods, so
  of-audio gives the mixer periods of 4410 frames at 44.1 kHz (147 x 30, 100 ms). 48 kHz then
  meets it at 4800 frames, 160/147: a table of 147 rows, made at once. (5880 frames did the same,
  but a program opening the sound with `snd_pcm_set_params` at 48 kHz then failed.) 96, 88.2 and 22.05 kHz
  meet it at simple ratios too.
- **32-bit as well as 16-bit** (`rate_openframe.c`, from alsa-plugins' `rate_speexrate.c`): a
  DAC mixed at 32 bits gets the 24 bits of a 24-bit source, through Speex's float path, rather
  than them being cut to 16 to be resampled.

## Measured

On an OpenFrame 1 (Atom Z520, 1.33 GHz), 48 kHz into the 44.1 kHz mixer, CPU for the playing app
(resampling and mixing), against linear's 1.5%:

| Converter | CPU |
|---|---|
| Debian's speexrate (quality 3) | 21% |
| speexrate_medium (quality 5), Debian's | 30% |
| openframe (quality 5), SSE2 and the direct table | 9% |

The same on an OpenFrame 2 with an Audient iD4 mixed at 32 bits: 9.6%. Quality 10 (`_best`) is
30% even built this way, for no difference that can be heard.

## Building

`build.sh` runs in an i386 Debian Trixie container; `.github/workflows/resampler.yml` builds,
tests and publishes the package to the testing suite, as `crystalhd.yml` does.
