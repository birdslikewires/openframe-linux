#!/bin/bash
# Prints the openframe-scripts version built from overlay directory $1 (such as
# overlay-debian-trixie/), from the repository's root with its full history. The
# package workflow builds that version, and the image workflow waits for it.
#
# Version is year.month.N, where N counts the commits that changed the package in
# that month (the third this month is 26.11.3). Every path the package is built from
# must be listed below, as must the workflow that builds it: a commit touching only an
# unlisted one would rebuild the package under the version units already have, so they
# would never get it. Adding paths only ever counts more commits, so the version can't
# go backwards. The 1: epoch puts it above the old
# YYYYMMDD-1 versions.

overlay_dir="$1"
paths=("${overlay_dir}usr/local/bin/of-*" "${overlay_dir}usr/local/sbin/of-*" \
  "${overlay_dir}usr/share/kernel" "${overlay_dir}usr/lib/firmware/updates" \
  "${overlay_dir}usr/lib/udev/rules.d" "${overlay_dir}usr/lib/udev/hwdb.d" "${overlay_dir}usr/lib/openframe" \
  "${overlay_dir}usr/share/initramfs-tools" "${overlay_dir}usr/lib/systemd/system" \
  "${overlay_dir}usr/lib/sysctl.d" "${overlay_dir}etc/dpkg/dpkg.cfg.d/openframe-*" \
  "${overlay_dir}usr/share/keyrings" "${overlay_dir}usr/local/bin/readlightsensor" \
  "${overlay_dir}usr/lib/systemd/timesyncd.conf.d" "${overlay_dir}etc/apt/apt.conf.d/50openframe-*" \
  "${overlay_dir}etc/sensors.d/openframe.conf" "${overlay_dir}boot/backlight.txt" \
  "${overlay_dir}boot/settings" \
  .github/workflows/package.yml package)
month=$(TZ=UTC git log -1 --format=%cd --date=format-local:%y.%m -- "${paths[@]}")
count=$(TZ=UTC git log --format=%cd --date=format-local:%y.%m -- "${paths[@]}" | grep -cx "${month}")
[ -n "$month" ] && [ "$count" -gt 0 ] || { echo "Can't work out the version: no history?" >&2; exit 1; }
echo "1:${month%.*}.$((10#${month#*.})).${count}"
