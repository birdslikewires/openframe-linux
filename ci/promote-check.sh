#!/bin/bash
# ci/promote-check.sh: before promote.yml releases what's in testing, checks that every package
# the released suite would then hold can be installed on an OpenFrame that isn't a test unit,
# and that one already running the released suite can update to it by itself:
#   1. Installing: in an i386 Debian Trixie container, with Debian's suites and the other
#      OpenFrame repositories' released suites, as such a unit has them, and this repository's
#      released suite as it would be after the promote, all of them at once install. So
#      nothing is released that needs something still in testing (Sprite needing a newer
#      openframe-scripts, say), whatever order things are promoted in.
#   2. Updating: a unit with this repository's released suite as it is now installed (and any
#      apps, ofapp-*, from the other repositories), updated to the suite as it would be, has
#      nothing removed. A unit updates itself with unattended-upgrades, which never removes a
#      package to fit an update in: it skips that update, every night (of-update then says it
#      can't be installed by itself). So a package of ours that conflicts with one already on
#      units (a rename without Replaces, a Breaks on an app) is caught here, not on them.
#      The installed state is apt's own records written for those packages (no package's
#      scripts are run, as in a container they couldn't be), and the update apt's plan.
# Run from the repository's root with the repo branch in apt-repo/; needs only docker.
# Prints apt's complaint and exits non-zero if something can't be installed or updated to.
#   APT_SITE=linux.openbeak.net ci/promote-check.sh [<pkg>=<ver>...]
# With packages given, only those move from testing (as apt-suite.sh promote moves them).
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

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cat > "$W/check.sh" <<'INSIDE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get -qq update >/dev/null 2>&1
apt-get -qq install -y dpkg-dev >/dev/null 2>&1 || { echo "Couldn't install dpkg-dev: no network?"; exit 1; }
shopt -s nullglob

# The released pool as it is now (/released), and as the promote would leave it (/promoted):
# testing's packages in place of theirs.
mkdir -p /released /promoted
for d in /pool/trixie/*.deb; do cp "$d" /released/; cp "$d" /promoted/; done
for d in /pool/trixie-testing/*.deb; do
	p=$(dpkg-deb -f "$d" Package)
	if [ -n "$ONLY" ] && ! printf "%s\n" $ONLY | grep -qxF "$p=$(dpkg-deb -f "$d" Version)"; then continue; fi
	rm -f /promoted/"$p"_*.deb; cp "$d" /promoted/
done
debs=(/promoted/*.deb)
[ ${#debs[@]} -gt 0 ] || { echo "Nothing to check."; exit 0; }
(cd /promoted && dpkg-scanpackages . > Packages 2>/dev/null)
(cd /released && dpkg-scanpackages . > Packages 2>/dev/null)
pkgs=$(for d in "${debs[@]}"; do dpkg-deb -f "$d" Package; done | sort -u | tr "\n" " ")
printf "%s" "$OTHERS" > /etc/apt/sources.list.d/openframe.list
use() { echo "deb [trusted=yes] file:/$1 ./" > /etc/apt/sources.list.d/ours.list; apt-get -qq update 2>&1 | grep -v "^W:" || true; }

# 1. Installing: all of them at once, the newest of each (ours, as promoted).
echo "Checking that these install from ${SITE} once promoted: ${pkgs}"
use promoted
if ! apt-get -s install -y $pkgs > /tmp/out 2>&1; then
	echo "They wouldn't all install:"; grep -v "^Inst\|^Conf" /tmp/out; exit 1
fi
grep -E "^Inst (openframe|linux-image)" /tmp/out || true
echo "All of them install."

# 2. Updating: a unit on the released suite as it is (with any apps the other repositories
# have), updated to it as it would be. Its installed state: everything installing those would
# bring, written into a copy of dpkg's records as installed.
use released
now=$(cd /released && for d in *.deb; do dpkg-deb -f "$d" Package; done | sort -u | tr "\n" " ")
apps=$(apt-cache pkgnames ofapp- 2>/dev/null | sort -u | tr "\n" " ")
if [ -z "$now$apps" ]; then
	echo "Nothing released yet: no unit to update."
	exit 0
fi
echo "Checking that a unit with these as released now updates to them, removing nothing: ${now}${apps}"
if ! apt-get -s install -y $now $apps > /tmp/now 2>&1; then
	echo "The released suite as it is now doesn't install (so there's no unit to update from):"
	grep -v "^Inst\|^Conf" /tmp/now; exit 1
fi
sed -n "s/^Inst \([^ ]*\) \(\[[^]]*\] \)\{0,1\}(\([^ ]*\) .*/\1=\3/p" /tmp/now > /tmp/closure
# dpkg's records as they'd be: the base system's, less what the closure replaces, then each
# package of the closure as installed (its Packages entry, with a Status line)
cut -d= -f1 /tmp/closure | sort -u > /tmp/names
awk 'NR == FNR { n[$1] = 1; next } /^Package: / { skip = ($2 in n) } !skip' /tmp/names RS="" ORS="\n\n" /var/lib/dpkg/status > /tmp/status
while IFS= read -r pv; do
	apt-cache show "$pv" 2>/dev/null | awk 'BEGIN { RS = ""; ORS = "\n\n" } NR == 1 {
		sub(/\nStatus: [^\n]*/, ""); sub(/^Package: [^\n]*/, "&\nStatus: install ok installed"); print }'
done < /tmp/closure >> /tmp/status
# what came in only as something else needed it marked so (apt's extended_states), as on a unit
for p in $(cut -d= -f1 /tmp/closure); do
	case " $now $apps " in *" $p "*) continue ;; esac
	printf "Package: %s\nArchitecture: i386\nAuto-Installed: 1\n\n" "$p"
done > /tmp/extended_states
use promoted
S="-o Dir::State::status=/tmp/status -o Dir::State::extended_states=/tmp/extended_states -o Debug::NoLocking=1"
if ! apt-get -s $S dist-upgrade > /tmp/up 2>&1; then
	echo "A unit on the released suite couldn't update to it:"; grep -v "^Inst\|^Conf" /tmp/up; exit 1
fi
if grep -q "^Remv " /tmp/up; then
	echo "A unit on the released suite would have to remove packages to update, which it never does by"
	echo "itself (it would skip the update, every night). Removed, and what's installed in their place:"
	grep -E "^(Remv|Inst) " /tmp/up; exit 1
fi
# and nothing of ours kept back (apt holding it at the old version, rather than removing what
# it would take: as stuck)
kept=$(awk '/kept back:$/ { k = 1; next } k && /^  / { print; next } { k = 0 }' /tmp/up | tr -s " " "\n" | grep -v "^$" || true)
if [ -n "$kept" ]; then
	echo "A unit on the released suite would keep these back, never updating them by itself: $(echo $kept)"
	for p in $kept; do apt-get -s $S install "$p" 2>&1 | grep -E "^(Remv|Inst) |Breaks|Conflicts|Depends" || true; done
	exit 1
fi
grep -E "^Inst (openframe|linux-image|ofapp)" /tmp/up || true
echo "A unit on the released suite updates to it, removing nothing."
INSIDE

# As openframe-sprite's CI runs its i386 containers: the default seccomp profile stops 32-bit
# programs' newer system calls on GitHub's runners.
# (The script goes in on stdin: a file in a temporary folder can't always be mounted.)
docker run --rm -i --security-opt seccomp=unconfined --platform linux/386 \
	-v "$PWD/apt-repo/pool:/pool:ro" -v "$PWD/$KEY:/key.gpg:ro" \
	-e SITE="$SITE" -e OTHERS="$OTHERS" -e ONLY="$*" i386/debian:trixie bash -s < "$W/check.sh"
