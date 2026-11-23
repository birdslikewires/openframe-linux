#!/bin/bash
# test_apt_suite.sh: ci/apt-suite.sh, the testing and released suites of linux.openbeak.net:
# a publish goes to testing only; a unit with only the released suite doesn't see it, a test
# unit (both suites) does; "waiting" lists it; "promote" moves it to the released suite, which
# every unit then sees, leaving testing empty; signatures check. With a throwaway signing key,
# in a Debian Trixie container (Docker) unless it's root in one already:
#   bash tests/test_apt_suite.sh
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
if [ "$(id -u)" -ne 0 ] || [ ! -e /.dockerenv ]; then
	# i386, as an OpenFrame is, so apt takes the repository's i386 index as a unit does. As
	# openframe-sprite's CI runs it: the default seccomp profile stops 32-bit programs' newer
	# system calls on GitHub's runners (the network, for one).
	exec docker run --rm --security-opt seccomp=unconfined --platform linux/386 -v "$HERE:/src:ro" \
		i386/debian:trixie bash /src/tests/test_apt_suite.sh
fi
FAILS=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; [ -n "${2:-}" ] && sed 's/^/       /' <<< "$2" | tail -12; FAILS=$((FAILS + 1)); }
export DEBIAN_FRONTEND=noninteractive
apt-get -qq update >/dev/null 2>&1; apt-get -qq install -y dpkg-dev apt-utils gnupg >/dev/null 2>&1 ||
	{ echo "FAIL couldn't install the tools (dpkg-dev, apt-utils, gnupg): no network?"; exit 1; }
# Already in a container that isn't i386 (a CI job's own): apt takes i386 only, as a unit does
[ "$(dpkg --print-architecture)" = i386 ] || echo 'APT::Architecture "i386";' > /etc/apt/apt.conf.d/99i386

export GNUPGHOME=/tmp/gnupg; mkdir -m 700 -p $GNUPGHOME
gpg --batch --quiet --passphrase '' --quick-gen-key "test <t@t>" rsa2048 sign never >/dev/null 2>&1
FPR=$(gpg --with-colons --list-secret-keys | awk -F: '/^fpr/ { print $10; exit }')
export SIGN_ARGS="--local-user $FPR!"
gpg --export "$FPR" > /tmp/key.gpg

W=/work; mkdir -p $W && cd $W
deb() { # name version
	d=/tmp/b-$1-$2; mkdir -p $d/DEBIAN
	printf 'Package: %s\nVersion: %s\nArchitecture: all\nMaintainer: t <t@t>\nDescription: test\n' "$1" "$2" > $d/DEBIAN/control
	dpkg-deb --build --root-owner-group $d /tmp/$1_$2_all.deb >/dev/null
}
S=/src/ci/apt-suite.sh
deb pkg-a 1; deb pkg-a 2; deb pkg-b 1
bash $S add trixie /tmp/pkg-a_1_all.deb /tmp/pkg-b_1_all.deb >/dev/null && ok "released suite made" || bad "released suite made"
bash $S add trixie-testing /tmp/pkg-a_2_all.deb >/dev/null && ok "a publish to testing" || bad "a publish to testing"
[ "$(ls apt-repo/pool/trixie)" = "$(printf 'pkg-a_1_all.deb\npkg-b_1_all.deb')" ] && ok "the released pool is untouched" || bad "the released pool is untouched" "$(ls apt-repo/pool/trixie)"

# units: apt, reading the repository from disk
unit() { # sources...
	rm -f /etc/apt/sources.list.d/*; for s in "$@"; do echo "deb [signed-by=/tmp/key.gpg] file:$W/apt-repo $s main"; done > /etc/apt/sources.list.d/t.list
	apt-get -qq update -o Dir::Etc::sourcelist=/dev/null 2>&1 | grep -v "^$" ; apt-cache policy pkg-a | sed -n 's/^  Candidate: //p'
}
out=$(unit trixie); [ "$(tail -1 <<< "$out")" = 1 ] && ok "a released unit sees version 1" || bad "a released unit sees version 1" "$out"
out=$(unit trixie trixie-testing); [ "$(tail -1 <<< "$out")" = 2 ] && ok "a test unit sees version 2" || bad "a test unit sees version 2" "$out"
[ "$(bash $S waiting)" = "pkg-a 2 1" ] && ok "waiting lists it" || bad "waiting lists it" "$(bash $S waiting)"
out=$(bash $S promote); grep -qx "promoted pkg-a 2" <<< "$out" && ok "promote moves it" || bad "promote moves it" "$out"
[ "$(ls apt-repo/pool/trixie)" = "$(printf 'pkg-a_2_all.deb\npkg-b_1_all.deb')" ] && [ -z "$(ls apt-repo/pool/trixie-testing)" ] &&
	ok "the released pool has it in place of 1, testing is empty" || bad "the released pool has it in place of 1" "$(ls -R apt-repo/pool)"
out=$(unit trixie); [ "$(tail -1 <<< "$out")" = 2 ] && ok "every unit sees version 2" || bad "every unit sees version 2" "$out"
out=$(unit trixie trixie-testing); [ "$(tail -1 <<< "$out")" = 2 ] && ok "and a test unit still does" || bad "and a test unit still does" "$out"
[ -z "$(bash $S waiting)" ] && ok "nothing waiting" || bad "nothing waiting" "$(bash $S waiting)"
# "ok" releases what the issue listed then: pkg-a 3 was listed, pkg-b 2 arrived after
deb pkg-a 3; deb pkg-b 2
bash $S add trixie-testing /tmp/pkg-a_3_all.deb /tmp/pkg-b_2_all.deb >/dev/null
out=$(bash $S promote pkg-a=3)
grep -qx "promoted pkg-a 3" <<< "$out" && grep -qx "left in testing: pkg-b 2" <<< "$out" &&
	ok "promote with a list releases only what's listed" || bad "promote with a list releases only what's listed" "$out"
[ "$(bash $S waiting)" = "pkg-b 2 1" ] && ok "and the rest waits in testing" || bad "and the rest waits in testing" "$(bash $S waiting)"
out=$(bash $S promote pkg-b=3); grep -qx "left in testing: pkg-b 2" <<< "$out" && [ "$(bash $S waiting)" = "pkg-b 2 1" ] &&
	ok "a version that isn't the one listed stays" || bad "a version that isn't the one listed stays" "$out"
grep -q "^Label: OpenFrame Linux testing" apt-repo/dists/trixie-testing/Release && grep -q "^Codename: trixie-testing" apt-repo/dists/trixie-testing/Release &&
	ok "testing's Release is labelled as such (of-update's tiers, unattended-upgrades' -testing codename)" || bad "testing's Release labels" "$(cat apt-repo/dists/trixie-testing/Release)"
echo
[ "$FAILS" -eq 0 ] && echo "all passed" || echo "$FAILS failed"
exit "$FAILS"
