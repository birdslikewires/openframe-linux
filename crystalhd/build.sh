#!/bin/sh
# Builds the openframe-crystalhd package: the Crystal HD library with our fixes, the cards'
# firmware, and chdplay. Run as root in an i386 Debian Trixie container (the workflow uses
# i386/debian:trixie), as: sh build.sh <this folder> <version> <output folder>
#
# The library and firmware come from birdslikewires/crystalhd (twopoint71/crystalhd with our
# fixes) at a fixed commit, checked by its hash. The firmware is also checked against the
# copies Debian shipped in firmware-crystalhd (0.0~git20120110.fdd2f19-1), byte for byte.

set -eu

here=$1
version=$2
out=$3

UPSTREAM=https://github.com/birdslikewires/crystalhd.git
COMMIT=67bac2dac7a9056bf9d596b6e0fb5f011781b843
FW70015_MD5=213e2424b5f497105786b9e39f2f42ff
FW70012_MD5=47a30682b1b7355c2238f5d5f1920bcb
PKGNAME=openframe-crystalhd

export DEBIAN_FRONTEND=noninteractive
apt-get -qq --error-on=any update
apt-get -qq install -y --no-install-recommends ca-certificates git g++ make pkg-config \
  dpkg-dev file libdrm-dev libswscale-dev libavformat-dev libavcodec-dev libswresample-dev \
  libavutil-dev libasound2-dev > /dev/null

work=$(mktemp -d)
src=$work/src
git init -q "$src"
git -C "$src" fetch -q --depth 1 "$UPSTREAM" "$COMMIT"
git -C "$src" -c advice.detachedHead=false checkout -q FETCH_HEAD
[ "$(git -C "$src" rev-parse HEAD)" = "$COMMIT" ] || { echo "Fetched the wrong commit"; exit 1; }

printf '%s  %s\n%s  %s\n' \
  "$FW70015_MD5" "$src/firmware/fwbin/70015/bcm70015fw.bin" \
  "$FW70012_MD5" "$src/firmware/fwbin/70012/bcm70012fw.bin" | md5sum -c -

lib=$src/linux_lib/libcrystalhd
make -C "$lib" > /dev/null

avlibs="libdrm libswscale libavformat libavcodec libswresample libavutil alsa"
# shellcheck disable=SC2046
g++ -O2 -Wall -D__LINUX_USER__ -o "$work/chdplay" "$here/chdplay.cpp" \
  -I"$src/include" -I"$src/include/link" -I"$lib" $(pkg-config --cflags $avlibs) \
  -L"$lib" -lcrystalhd $(pkg-config --libs $avlibs) -pthread

multiarch=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
pkg=$work/pkg
install -d "$pkg/DEBIAN" "$pkg/usr/lib/$multiarch" "$pkg/usr/lib/firmware" "$pkg/usr/bin" \
  "$pkg/usr/share/doc/$PKGNAME"
# The library reads its firmware from /lib/firmware by name (not through the kernel's search
# path), so it goes there rather than in firmware/updates.
install -m 644 "$src/firmware/fwbin/70015/bcm70015fw.bin" "$src/firmware/fwbin/70012/bcm70012fw.bin" \
  "$pkg/usr/lib/firmware/"
install -m 644 "$lib/libcrystalhd.so.3.6" "$pkg/usr/lib/$multiarch/"
ln -s libcrystalhd.so.3.6 "$pkg/usr/lib/$multiarch/libcrystalhd.so.3"
install -m 755 "$work/chdplay" "$pkg/usr/bin/"
strip --strip-unneeded "$pkg/usr/lib/$multiarch/libcrystalhd.so.3.6" "$pkg/usr/bin/chdplay"
install -m 644 "$here/copyright" "$pkg/usr/share/doc/$PKGNAME/copyright"

# Dependencies from the libraries chdplay and libcrystalhd link to. dpkg-shlibdeps wants a
# debian/control, and our own library is listed so it doesn't go looking for its package.
mkdir -p "$work/debian"
printf 'Source: %s\n\nPackage: %s\nArchitecture: i386\n' "$PKGNAME" "$PKGNAME" > "$work/debian/control"
echo "libcrystalhd 3 $PKGNAME" > "$work/shlibs.local"
deps=$(cd "$work" && dpkg-shlibdeps -O -L"$work/shlibs.local" -x"$PKGNAME" \
  -l"$pkg/usr/lib/$multiarch" "$pkg/usr/bin/chdplay" "$pkg/usr/lib/$multiarch/libcrystalhd.so.3.6")
deps=${deps#shlibs:Depends=}
[ -n "$deps" ] || { echo "No dependencies found"; exit 1; }

echo "libcrystalhd 3 $PKGNAME (>= ${version})" > "$pkg/DEBIAN/shlibs"
echo "activate-noawait ldconfig" > "$pkg/DEBIAN/triggers"
size=$(du -sk --exclude=DEBIAN "$pkg" | cut -f1)
cat > "$pkg/DEBIAN/control" << EOF
Package: $PKGNAME
Version: $version
Architecture: i386
Section: video
Priority: optional
Maintainer: OpenFrame <andy@dvsn.net>
Installed-Size: $size
Depends: $deps
Conflicts: libcrystalhd3, firmware-crystalhd
Replaces: libcrystalhd3, firmware-crystalhd
Homepage: https://github.com/birdslikewires/openframe-linux
Description: Broadcom Crystal HD video decoder support for OpenFrames
 The Crystal HD library (libcrystalhd) with OpenFrame fixes, the firmware for the
 BCM70012 and BCM70015 decoders, and chdplay, a player that decodes H.264 on the
 card and shows it on the panel with sound. Files, HTTPS and HLS streams play.
 .
 The card's kernel driver, crystalhd, comes with the OpenFrame kernel.
EOF

deb="$out/${PKGNAME}_${version}_i386.deb"
dpkg-deb --build --root-owner-group "$pkg" "$deb" > /dev/null
dpkg-deb --info "$deb"
dpkg-deb --contents "$deb"
