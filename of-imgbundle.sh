#!/usr/bin/env bash

## of-imgbundle.sh v26.11.1 (15th November 2026)
##  Puts a compressed copy of an OpenFrame image inside that image's own root filesystem,
##  so one download is both a system and an installer: the installer (of-flash) writes
##  the copy to an OpenFrame 1's internal memory without needing a network. The copy is
##  the image as it was before this, so what gets installed is exactly the image that was
##  built, with no copy inside it.
##
##  The copy goes to /usr/lib/openframe/install/image.img.gz, with image.info beside it:
##    name=   the image's file name, without .img
##    size=   its size in bytes
##    md5=    the md5 of the image (what the internal memory reads back after writing)
##    gzmd5=  the md5 of image.img.gz
##
##  Usage: of-imgbundle.sh <image.img>   (as root: it mounts the image's root filesystem)

set -euo pipefail

usage() {
	echo "Usage: $0 <image.img>"
	exit 1
}

[ $# -eq 1 ] && [ -f "$1" ] || usage
if [ "$(id -u)" -ne 0 ]; then
	echo "You need to run this with superuser privileges. Try 'sudo $0'."
	exit 1
fi

IMG="$1"
NAME="$(basename "$IMG" .img)"
DEST="usr/lib/openframe/install"
LOOP="/dev/of-loop2"
WORK="$(mktemp -d)"
MOUNTED=""
LOOPED=""

cleanup() {
	[ -z "$MOUNTED" ] || umount "$WORK/root" || true
	[ -z "$LOOPED" ] || losetup -d "$LOOP" || true
	rm -rf "$WORK"
}
trap cleanup EXIT

# The root filesystem is the image's second partition. Its own loop device, as
# of-imgcreate.sh does, so as not to compete with anything else for one.
part_bytes() {
	parted -m "$IMG" unit b print | grep "^2:" | cut -d: -f "$1" | sed -e 's/B$//'
}
OFFSET="$(part_bytes 2)"
PSIZE="$(part_bytes 4)"
[[ "$OFFSET" =~ ^[0-9]+$ ]] && [[ "$PSIZE" =~ ^[0-9]+$ ]] || { echo "No second partition in $IMG."; exit 1; }

echo "Compressing a copy of $NAME..."
SIZE="$(stat -c %s "$IMG")"
MD5="$(md5sum < "$IMG" | cut -d' ' -f1)"
# -n leaves the name and time out, so the same image always compresses the same.
gzip -9 -n -c "$IMG" > "$WORK/image.img.gz"
GZMD5="$(md5sum < "$WORK/image.img.gz" | cut -d' ' -f1)"
GZSIZE="$(stat -c %s "$WORK/image.img.gz")"
printf 'name=%s\nsize=%s\nmd5=%s\ngzmd5=%s\n' "$NAME" "$SIZE" "$MD5" "$GZMD5" > "$WORK/image.info"
echo "  $SIZE bytes (md5 $MD5), compressed to $GZSIZE bytes."

[ -e "$LOOP" ] || mknod "$LOOP" b 7 202
losetup "$LOOP" --offset "$OFFSET" --sizelimit "$PSIZE" "$IMG"
LOOPED=1
mkdir "$WORK/root"
mount "$LOOP" "$WORK/root"
MOUNTED=1

# Room for the copy, with 64 MB to spare for the system's first boot.
AVAIL="$(df -B1 --output=avail "$WORK/root" | tail -1 | tr -d ' ')"
if [ "$AVAIL" -lt $((GZSIZE + 64 * 1024 * 1024)) ]; then
	echo "Not enough room in the image's root filesystem: $AVAIL bytes free, the copy needs $GZSIZE and 64 MB to spare."
	exit 1
fi

install -d -m 755 "$WORK/root/$DEST"
install -m 644 "$WORK/image.img.gz" "$WORK/root/$DEST/image.img.gz"
install -m 644 "$WORK/image.info" "$WORK/root/$DEST/image.info"
sync
[ "$(md5sum < "$WORK/root/$DEST/image.img.gz" | cut -d' ' -f1)" = "$GZMD5" ] || { echo "The copy in the image doesn't match."; exit 1; }

umount "$WORK/root"
MOUNTED=""
e2fsck -fn "$LOOP" > /dev/null 2>&1 || { echo "The root filesystem has errors after adding the copy."; exit 1; }
losetup -d "$LOOP"
LOOPED=""

echo "Added the copy to $IMG ($DEST/image.img.gz):"
cat "$WORK/image.info"
