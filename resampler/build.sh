#!/bin/sh
# Builds the openframe-resampler package: ALSA's "openframe" rate converter (rate_openframe.c),
# the Speex resampler at quality 5, built in with SSE2. Run as root in an i386 Debian Trixie
# container (the workflow uses i386/debian:trixie), as:
#   sh build.sh <this folder> <version> <output folder>
#
# The resampler is speexdsp's resample.c from Debian's source package (trixie), checked by
# its md5 so resample-direct.patch applies to the code it was written for. Only that file is
# used; it's built into the plugin, so there's no libspeexdsp to depend on.

set -eu

here=$1
version=$2
out=$3

RESAMPLE_MD5=d9954e2a7f2373425bff91ec2b452e83   # speexdsp 1.2.1's libspeexdsp/resample.c
PKGNAME=openframe-resampler

export DEBIAN_FRONTEND=noninteractive
sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources
apt-get -qq --error-on=any update
apt-get -qq install -y --no-install-recommends gcc libc6-dev libasound2-dev dpkg-dev patch file > /dev/null

work=$(mktemp -d)
(cd "$work" && apt-get source -qq speexdsp > /dev/null 2>&1)
spx=$(find "$work" -maxdepth 1 -type d -name 'speexdsp-*' | head -1)
[ -n "$spx" ] || { echo "Couldn't fetch speexdsp's source"; exit 1; }
echo "$RESAMPLE_MD5  $spx/libspeexdsp/resample.c" | md5sum -c -
(cd "$spx" && patch -p1 < "$here/resample-direct.patch")

# Float, with speexdsp's SSE and SSE2 inner loops: every OpenFrame's Atom (Z5xx) has SSE3.
# RANDOM_PREFIX gives the resampler's functions names of their own, and they're hidden.
CFLAGS="-O2 -fPIC -Wall -DFLOATING_POINT -DOUTSIDE_SPEEX -DRANDOM_PREFIX=ofrate -DEXPORT=
  -msse2 -mfpmath=sse -D_USE_SSE -D_USE_SSE2 -I$spx/include/speex -I$spx/libspeexdsp"
# shellcheck disable=SC2086
gcc $CFLAGS -fvisibility=hidden -c "$spx/libspeexdsp/resample.c" -o "$work/resample.o"
# shellcheck disable=SC2086
gcc $CFLAGS -c "$here/rate_openframe.c" -o "$work/rate_openframe.o"
gcc -shared -Wl,-z,defs -o "$work/libasound_module_rate_openframe.so" "$work/rate_openframe.o" "$work/resample.o" -lasound -lm
strip --strip-unneeded "$work/libasound_module_rate_openframe.so"
# Its entry point for alsa-lib, and nothing of the resampler's (hidden: no clash with a
# libspeexdsp that something else loads).
syms=$(nm -D --defined-only "$work/libasound_module_rate_openframe.so" | awk '$2 == "T" { print $3 }')
echo "Exported: $syms"
echo "$syms" | grep -qx '_snd_pcm_rate_openframe_open'
if echo "$syms" | grep -q 'resampler'; then echo "The resampler's functions are exported"; exit 1; fi

multiarch=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
pkg=$work/pkg
install -d "$pkg/DEBIAN" "$pkg/usr/lib/$multiarch/alsa-lib" "$pkg/usr/share/doc/$PKGNAME"
install -m 644 "$work/libasound_module_rate_openframe.so" "$pkg/usr/lib/$multiarch/alsa-lib/"
install -m 644 "$here/copyright" "$pkg/usr/share/doc/$PKGNAME/copyright"

mkdir -p "$work/debian"
printf 'Source: %s\n\nPackage: %s\nArchitecture: i386\n' "$PKGNAME" "$PKGNAME" > "$work/debian/control"
deps=$(cd "$work" && dpkg-shlibdeps -O "$pkg/usr/lib/$multiarch/alsa-lib/libasound_module_rate_openframe.so")
deps=${deps#shlibs:Depends=}
[ -n "$deps" ] || { echo "No dependencies found"; exit 1; }

size=$(du -sk --exclude=DEBIAN "$pkg" | cut -f1)
cat > "$pkg/DEBIAN/control" << EOF
Package: $PKGNAME
Version: $version
Architecture: i386
Section: sound
Priority: optional
Maintainer: OpenFrame <andy@dvsn.net>
Installed-Size: $size
Depends: $deps
Homepage: https://github.com/birdslikewires/openframe-linux
Description: OpenFrame's sample rate converter for ALSA
 The "openframe" rate converter: the Speex resampler at quality 5, built for the
 OpenFrame's Atom (SSE2), for 16-bit and 32-bit audio. of-audio (openframe-scripts)
 has the OpenFrame's mixer use it for audio at another rate (48 kHz into the 44.1 kHz
 mixer, say), in place of ALSA's own linear converter.
EOF

deb="$out/${PKGNAME}_${version}_i386.deb"
dpkg-deb --build --root-owner-group "$pkg" "$deb" > /dev/null
dpkg-deb --info "$deb"
dpkg-deb --contents "$deb"
