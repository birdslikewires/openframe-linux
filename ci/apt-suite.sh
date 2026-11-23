#!/bin/bash
# ci/apt-suite.sh: the apt repository's work for linux.openbeak.net, shared by the workflows that
# publish to it (package.yml, sprite.yml, crystalhd.yml) and the one that promotes (promote.yml).
# openframe-firmware has a copy for firmware.openbeak.net, run with APT_NAME="OpenFrame Firmware".
# Run from the repository's root, with the repo branch checked out in apt-repo/ and the
# signing keys imported (SIGN_ARGS, as the workflows set it).
#
#   apt-suite.sh add <suite> <deb>...   put each .deb in pool/<suite>, replacing the package's
#                                       older versions there, and index the suite again
#   apt-suite.sh promote [<pkg>=<ver>...]
#                                       move packages in trixie-testing to trixie (the released
#                                       suite), and index both again: just those versions, if
#                                       given (what the testing issue listed when Andy said ok),
#                                       else all of them
#   apt-suite.sh waiting                list what's in testing and not released yet, a line
#                                       each: package, testing version, released version
#   apt-suite.sh index <suite>          index a suite again (Packages, Release, signatures)
#   apt-suite.sh listing                the repository's index.html: every package, both pools
#
# Two suites: trixie, what every OpenFrame takes, and trixie-testing, what test units take as
# well (OF-BOOT/settings/test.txt). Pushes publish to testing; a package reaches trixie only
# when it's promoted, by Andy's "ok" in reply to the repository's testing issue. Each pool holds
# one version of each package. Notes for owners (news/) are shared: of-update shows only those
# between the version a unit has and the one it's offered.
set -eu
REPO=apt-repo
NAME=${APT_NAME:-OpenFrame Linux}   # the repository's label (OpenFrame Firmware for firmware.openbeak.net)
RELEASED=trixie
TESTING=trixie-testing

index() {
	local suite=$1 label="$NAME" desc="$NAME packages"
	[ "$suite" = "$TESTING" ] && { label="$NAME testing"; desc="$NAME packages before release, for test units"; }
	mkdir -p "$REPO/pool/$suite" "$REPO/dists/$suite/main/binary-i386"
	(
		cd "$REPO"
		dpkg-scanpackages "pool/$suite" > "dists/$suite/main/binary-i386/Packages" 2>/dev/null
		gzip -kf "dists/$suite/main/binary-i386/Packages"
		apt-ftparchive \
			-o APT::FTPArchive::Release::Origin="OpenFrame" \
			-o APT::FTPArchive::Release::Label="$label" \
			-o APT::FTPArchive::Release::Suite="$suite" \
			-o APT::FTPArchive::Release::Codename="$suite" \
			-o APT::FTPArchive::Release::Architectures="all i386" \
			-o APT::FTPArchive::Release::Components="main" \
			-o APT::FTPArchive::Release::Description="$desc" \
			release "dists/$suite" > "dists/$suite/Release.new"
		mv -f "dists/$suite/Release.new" "dists/$suite/Release"
		# shellcheck disable=SC2086
		gpg --batch --yes ${SIGN_ARGS:-} --detach-sign --armor -o "dists/$suite/Release.gpg" "dists/$suite/Release"
		# shellcheck disable=SC2086
		gpg --batch --yes ${SIGN_ARGS:-} --clearsign -o "dists/$suite/InRelease" "dists/$suite/Release"
	)
}

# The package and version in a .deb.
field() { dpkg-deb -f "$1" "$2"; }

case "${1:-}" in
add)
	suite=$2; shift 2
	mkdir -p "$REPO/pool/$suite"
	for deb in "$@"; do
		pkg=$(field "$deb" Package)
		rm -f "$REPO/pool/$suite/${pkg}"_*.deb
		cp "$deb" "$REPO/pool/$suite/"
	done
	index "$suite"
	;;
promote)
	shift
	shopt -s nullglob
	moved=0
	for deb in "$REPO/pool/$TESTING"/*.deb; do
		pkg=$(field "$deb" Package)
		if [ $# -gt 0 ] && ! printf '%s\n' "$@" | grep -qxF "$pkg=$(field "$deb" Version)"; then
			echo "left in testing: $pkg $(field "$deb" Version)"   # not what was said ok to
			continue
		fi
		rm -f "$REPO/pool/$RELEASED/${pkg}"_*.deb
		mv "$deb" "$REPO/pool/$RELEASED/"
		echo "promoted $pkg $(field "$REPO/pool/$RELEASED/${deb##*/}" Version)"
		moved=$((moved + 1))
	done
	index "$RELEASED"
	index "$TESTING"
	[ "$moved" -gt 0 ] || echo "nothing in testing to promote"
	;;
waiting)
	shopt -s nullglob
	for deb in "$REPO/pool/$TESTING"/*.deb; do
		pkg=$(field "$deb" Package)
		rel=""
		for r in "$REPO/pool/$RELEASED/${pkg}"_*.deb; do rel=$(field "$r" Version); done
		printf '%s %s %s\n' "$pkg" "$(field "$deb" Version)" "${rel:-none}"
	done
	;;
index)
	index "$2"
	;;
listing)
	human() {
		if [ "$1" -ge 1073741824 ]; then echo "$(($1 / 1073741824))G"
		elif [ "$1" -ge 1048576 ]; then echo "$(($1 / 1048576))M"
		elif [ "$1" -ge 1024 ]; then echo "$(($1 / 1024))K"
		else echo "$1"; fi
	}
	cd "$REPO"
	{
		printf '<!DOCTYPE html>\n<html>\n<head><title>Index of /</title></head>\n<body>\n<h1>Index of /</h1><hr><pre>'
		for f in pool/*/*.deb; do
			[ -f "$f" ] || continue
			name=${f##*/}
			pad=$((51 - ${#name})); [ "$pad" -lt 1 ] && pad=1
			printf '\n<a href="%s">%s</a>%*s%s  %8s' "$f" "$name" "$pad" '' \
				"$(date -d "@$(stat -c %Y "$f")" '+%d-%b-%Y %H:%M')" "$(human "$(stat -c %s "$f")")"
		done
		printf '\n</pre><hr></body>\n</html>\n'
	} > index.html
	;;
*)
	sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
	exit 2
	;;
esac
