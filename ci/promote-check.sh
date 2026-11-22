#!/bin/bash
# ci/promote-check.sh: before promote.yml releases what's in testing, checks that every package
# the released suite would then hold can be installed on an OpenFrame that isn't a test unit:
# in an i386 Debian Trixie container, with Debian's suites and the other OpenFrame
# repositories' released suites, as such a unit has them, and this repository's released suite
# as it would be after the promote. So nothing is released that needs something still in
# testing (Sprite needing a newer openframe-scripts, say), whatever order things are promoted
# in. Run from the repository's root with the repo branch in apt-repo/; needs only docker.
# Prints apt's complaint and exits non-zero if something can't be installed.
#   APT_SITE=linux.openbeak.net ci/promote-check.sh
set -eu
SITE=${APT_SITE:-linux.openbeak.net}
KEY=$(ls overlay-*/usr/share/keyrings/openframe-apt.gpg 2>/dev/null | head -1)
[ -n "$KEY" ] || KEY=ci/openframe-apt.gpg   # (repositories without the overlay carry a copy)
[ -d apt-repo/pool ] || { echo "No apt-repo/pool here."; exit 1; }

# The other OpenFrame repositories, released suites only, as a unit that isn't a test unit has.
OTHERS=""
for s in linux.openbeak.net:main kernel.openbeak.net:6.18 firmware.openbeak.net:main; do
	[ "${s%%:*}" = "$SITE" ] && continue
	OTHERS="${OTHERS}deb [signed-by=/key.gpg] https://${s%%:*}/ trixie ${s#*:}
"
done

# As openframe-sprite's CI runs its i386 containers: the default seccomp profile stops 32-bit
# programs' newer system calls on GitHub's runners.
docker run --rm --security-opt seccomp=unconfined --platform linux/386 \
	-v "$PWD/apt-repo/pool:/pool:ro" -v "$PWD/$KEY:/key.gpg:ro" \
	-e SITE="$SITE" -e OTHERS="$OTHERS" i386/debian:trixie bash -euc '
	export DEBIAN_FRONTEND=noninteractive
	apt-get -qq update >/dev/null 2>&1
	apt-get -qq install -y dpkg-dev >/dev/null 2>&1 || { echo "Couldn'\''t install dpkg-dev: no network?"; exit 1; }
	# the released pool as the promote would leave it: testing'\''s packages in place of theirs
	mkdir -p /promoted
	shopt -s nullglob
	for d in /pool/trixie/*.deb; do cp "$d" /promoted/; done
	for d in /pool/trixie-testing/*.deb; do
		rm -f /promoted/"$(dpkg-deb -f "$d" Package)"_*.deb; cp "$d" /promoted/
	done
	debs=(/promoted/*.deb)
	[ ${#debs[@]} -gt 0 ] || { echo "Nothing to check."; exit 0; }
	(cd /promoted && dpkg-scanpackages . > Packages 2>/dev/null)
	pkgs=$(for d in "${debs[@]}"; do dpkg-deb -f "$d" Package; done | sort -u | tr "\n" " ")
	echo "Checking that these install from ${SITE} once promoted: ${pkgs}"
	printf "%s" "$OTHERS" > /etc/apt/sources.list.d/openframe.list
	echo "deb [trusted=yes] file:/promoted ./" > /etc/apt/sources.list.d/promoted.list
	apt-get -qq update 2>&1 | grep -v "^W:" || true
	# a simulation: all of them at once, the newest of each (ours, as promoted)
	if ! apt-get -s install -y $pkgs > /tmp/out 2>&1; then
		echo "They wouldn'\''t all install:"; grep -v "^Inst\|^Conf" /tmp/out; exit 1
	fi
	grep -E "^Inst (openframe|linux-image)" /tmp/out || true
	echo "All of them install."'
