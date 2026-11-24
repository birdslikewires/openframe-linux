#!/bin/bash
# Prints the openframe-scripts version built from overlay directory $1 (such as
# overlay-debian-trixie/), from the repository's root with its full history; with --news
# as $2, the owners' notes for every version (below). The
# package workflow builds that version, and the image workflow waits for it.
#
# Version is year.month.N, where N counts the commits that changed the package in
# that month (the third this month is 26.11.3). Every path the package is built from
# must be listed below, as must the workflow that builds it: a commit touching only an
# unlisted one would rebuild the package under the version units already have, so they
# would never get it. Adding paths only ever counts more commits, so the version can't
# go backwards. (Until 26.11.171 it had a 1: epoch, to rank above the old YYYYMMDD-1
# versions; dropped with the first-release images, which nothing older updates to.)

overlay_dir="$1"
[ "${2:-}" = --news ] && NEWS=1
paths=("${overlay_dir}usr/local/bin/of-*" "${overlay_dir}usr/local/sbin/of-*" \
  "${overlay_dir}usr/share/kernel" "${overlay_dir}usr/lib/firmware/updates" \
  "${overlay_dir}usr/lib/udev/rules.d" "${overlay_dir}usr/lib/udev/hwdb.d" "${overlay_dir}usr/lib/openframe" \
  "${overlay_dir}usr/share/initramfs-tools" "${overlay_dir}usr/lib/systemd/system" \
  "${overlay_dir}usr/lib/sysctl.d" "${overlay_dir}etc/dpkg/dpkg.cfg.d/openframe-*" \
  "${overlay_dir}usr/lib/modules-load.d" "${overlay_dir}usr/share/plymouth/themes" \
  "${overlay_dir}usr/share/keyrings" "${overlay_dir}usr/local/bin/readlightsensor" \
  "${overlay_dir}usr/lib/systemd/timesyncd.conf.d" "${overlay_dir}etc/apt/apt.conf.d/50openframe-*" \
  "${overlay_dir}etc/apt/apt.conf.d/52openframe-*" "${overlay_dir}etc/apt/preferences.d/openframe-*" \
  "${overlay_dir}etc/sensors.d/openframe.conf" "${overlay_dir}boot/backlight.txt" \
  "${overlay_dir}boot/settings" \
  .github/workflows/package.yml package)
# With --news: the owners' notes instead, from the "News:" lines of the commits that made
# each version, newest first, a line each: the version, a tab, the note. A commit may carry
# several; most carry none ("Bug fixes and improvements", as Sprite puts it).
if [ "${NEWS:-}" ]; then
	TZ=UTC git log --reverse --format='%H %cd' --date=format-local:%y.%m -- "${paths[@]}" |
		awk '{ n[$2]++; m = $2; sub(/\..*/, "", m); mm = substr($2, 4) + 0; print $1, m "." mm "." n[$2] }' |
		while read -r hash ver; do
			i=$((${i:-0} + 1))
			# Each "News:" line anywhere in the message, running on to a blank line, the next
			# News: line or a trailer of ours, its lines joined (so a wrapped line starting
			# "Settings: ..." stays in the note): not git's trailers alone, which only count in the
			# message's last paragraph and fold only indented lines (a News: paragraph before
			# the Co-Authored-By one, or a note wrapped onto a plain line, was missed)
			git log -1 --format=%B "$hash" | awk '
				function out() { if (n != "") print n; n = "" }
				/^News:/ { out(); n = $0; sub(/^News:[ \t]*/, "", n); next }
				n != "" && (/^[ \t]*$/ || /^(Co-Authored-By|Claude-Session|Signed-off-by):/) { out(); next }
				n != "" { l = $0; sub(/^[ \t]+/, "", l); n = n " " l }
				END { out() }' |
				awk -v i="$i" -v v="$ver" '{ print i "\t" NR "\t" v "\t" $0 }'
		done | sort -t "$(printf '\t')" -k1,1nr -k2,2n | cut -f3-
	exit 0
fi

month=$(TZ=UTC git log -1 --format=%cd --date=format-local:%y.%m -- "${paths[@]}")
count=$(TZ=UTC git log --format=%cd --date=format-local:%y.%m -- "${paths[@]}" | grep -cx "${month}")
[ -n "$month" ] && [ "$count" -gt 0 ] || { echo "Can't work out the version: no history?" >&2; exit 1; }
echo "${month%.*}.$((10#${month#*.})).${count}"
