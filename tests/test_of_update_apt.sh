#!/bin/bash
# test_of_update_apt.sh: of-update-apt (overlay-debian-trixie/usr/lib/openframe/of-update-apt), against real apt and dpkg, with small made-up packages in two local repositories, "OpenFrame" and "OpenFrame Apps", and Debian's own sources switched off: plan lists each update with its tier, size, file, old version and where it's from; upgrade installs them, new packages they need included; an upgrade that would remove a system package is held back, with why, and one that removes only an app goes in, the app named; a package on hold stays; what upgrades leave unused is removed; and the state file shows how it went.
# It needs root and apt, so it runs itself in a Debian Trixie container (Docker) unless it's root already:
#   bash tests/test_of_update_apt.sh
# Prints one line per case; exits non-zero if any case fails.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
if [ "$(id -u)" -ne 0 ] || [ ! -e /.dockerenv ]; then
	exec docker run --rm -v "$HERE:/src:ro" debian:trixie bash /src/tests/test_of_update_apt.sh
fi

FAILS=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; [ -n "${2:-}" ] && sed 's/^/       /' <<< "$2" | tail -15; FAILS=$((FAILS + 1)); }

export DEBIAN_FRONTEND=noninteractive LC_ALL=C
apt-get update -qq >/dev/null && apt-get install -y -qq python3-apt apt-utils dpkg-dev >/dev/null 2>&1 || { echo "couldn't install python3-apt"; exit 1; }
H=/usr/lib/openframe/of-update-apt
install -D -m 755 /src/overlay-debian-trixie/usr/lib/openframe/of-update-apt "$H"
# Only our repositories from here on
rm -f /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list

# mkpkg REPO NAME VERSION [FIELD: VALUE]...: a package of nothing but a file of its own, into /repo/REPO
mkpkg() {
	local repo=$1 n=$2 v=$3 d
	shift 3
	d=$(mktemp -d)
	mkdir -p "$d/DEBIAN" "$d/usr/share/$n"
	echo "$n $v" > "$d/usr/share/$n/version"
	head -c 20000 /dev/urandom > "$d/usr/share/$n/data"   # a size worth counting
	{ echo "Package: $n"; echo "Version: $v"; echo "Architecture: all"; echo "Maintainer: test <t@t>"; echo "Description: $n"; for f in "$@"; do echo "$f"; done; } > "$d/DEBIAN/control"
	mkdir -p /repo/$repo
	dpkg-deb -b "$d" "/repo/$repo/${n}_${v}_all.deb" >/dev/null
	rm -rf "$d"
}
publish() {
	local repo origin
	for repo in of apps; do
		origin="OpenFrame"; [ $repo = apps ] && origin="OpenFrame Apps"
		mkdir -p /repo/$repo
		(cd /repo/$repo && apt-ftparchive packages . > Packages && apt-ftparchive -o "APT::FTPArchive::Release::Origin=$origin" -o "APT::FTPArchive::Release::Label=$origin" -o APT::FTPArchive::Release::Codename=trixie release . > Release)
	done
	apt-get update -qq >/dev/null 2>&1
}
printf 'deb [trusted=yes] file:/repo/of ./\ndeb [trusted=yes] file:/repo/apps ./\n' > /etc/apt/sources.list.d/test.list
# keep a package's settings as the unit has them, as 52openframe-updates does
printf 'Dpkg::Options { "--force-confdef"; "--force-confold"; };\n' > /etc/apt/apt.conf.d/52test

# What's installed to begin with: demo 1 (needing oldlib, installed for it), keepme, sysx 1, sysy 1, the app ofapp-old, held 1 (on hold), and ofapp-clock 1
mkpkg of demo 1 "Depends: oldlib"
mkpkg of oldlib 1
mkpkg of keepme 1
mkpkg of sysx 1
mkpkg of sysy 1
mkpkg of held 1
mkpkg apps ofapp-old 1
mkpkg apps ofapp-clock 1
publish
apt-get install -y -qq demo keepme sysx sysy held ofapp-old ofapp-clock >/dev/null 2>&1 || { echo "couldn't install the starting packages"; exit 1; }
apt-mark hold held >/dev/null
# The updates: demo 2 (no longer needing oldlib, needing newdep, new), sysx 2 (conflicting with keepme: held back), sysy 2 (conflicting with the app ofapp-old: goes in, the app goes), held 2, ofapp-clock 2
mkpkg of demo 2 "Depends: newdep"
mkpkg of newdep 1
mkpkg of sysx 2 "Conflicts: keepme"
mkpkg of sysy 2 "Conflicts: ofapp-old"
mkpkg of held 2
mkpkg apps ofapp-clock 2
publish

L=/var/lib/of-update/pending.list HL=/var/lib/of-update/held.list
mkdir -p /run/of-update

# lists: fetched and read, to 100%; a repository that isn't there is named, and it fails as apt-get update --error-on=any does
printf 'state=checking\nsince=1\nkind=check\n' > /run/of-update/state
out=$("$H" lists 2>&1); r=$?
[ $r = 0 ] && grep -qx "percent=100" /run/of-update/state && grep -qx "kind=check" /run/of-update/state && apt-cache policy demo | grep -q "Candidate: 2" &&
	ok "lists: fetched and read, to 100%" || bad "lists: fetched and read" "r=$r $out $(cat /run/of-update/state)"
echo "deb [trusted=yes] file:/repo/missing ./" > /etc/apt/sources.list.d/missing.list
out=$("$H" lists 2>&1); r=$?
[ $r = 100 ] && grep -q "^E: Failed to fetch file:/repo/missing" <<< "$out" && grep -q "^E: Some index files failed to download" <<< "$out" &&
	ok "lists: a repository that isn't there is named, and it fails" || bad "lists: a missing repository" "r=$r $out"
rm /etc/apt/sources.list.d/missing.list
"$H" lists >/dev/null 2>&1
printf 'state=preparing\nsince=1\nkind=update\n' > /run/of-update/state

"$H" plan 2>/tmp/err || bad "plan runs" "$(cat /tmp/err)"
line() { grep "^$1	" "$L"; }
[ "$(line demo | cut -f2,3,6)" = "$(printf '2\topenframe\t1')" ] && [ "$(line demo | cut -f5)" = demo_2_all.deb ] && (( $(line demo | cut -f4) > 20000 )) &&
	[ "$(line demo | cut -f7)" = "file:/repo/of/./demo_2_all.deb" ] &&
	ok "plan: an upgrade, its tier, file, size, old version and where it's from" || bad "plan: an upgrade" "$(cat "$L")"
[ "$(line newdep | cut -f2,3,6)" = "$(printf '1\topenframe\t')" ] && ok "plan: a new package an upgrade needs is in it" || bad "plan: a new package" "$(cat "$L")"
[ "$(line ofapp-clock | cut -f3)" = apps ] && ok "plan: an app is in the apps tier" || bad "plan: an app's tier" "$(cat "$L")"
! line sysx >/dev/null && [ "$(cat "$HL")" = "$(printf 'sysx\tit would remove keepme')" ] &&
	ok "plan: an upgrade that would remove a system package is held back, with why" || bad "plan: held back" "$(cat "$L" "$HL")"
line sysy >/dev/null && ok "plan: an upgrade that removes only an app is in" || bad "plan: removing an app" "$(cat "$L" "$HL")"
! line held >/dev/null && ! grep -q '^held	' "$HL" && ok "plan: a package on hold stays" || bad "plan: on hold" "$(cat "$L" "$HL")"
! line oldlib >/dev/null && ! line keepme >/dev/null && ok "plan: nothing else is listed" || bad "plan: nothing else" "$(cat "$L")"

"$H" upgrade >/tmp/err 2>&1; r=$?
vs() { dpkg-query -W -f='${Version} ${db:Status-Abbrev}' "$1" 2>/dev/null; }
v() { vs "$1" | grep ' .i '; }   # (installed, or nothing)
[ $r = 0 ] && [ "$(v demo)" = "2 ii " ] && [ "$(v newdep)" = "1 ii " ] && [ "$(v sysy)" = "2 ii " ] && [ "$(v ofapp-clock)" = "2 ii " ] &&
	ok "upgrade: the plan is installed" || bad "upgrade: installed" "r=$r $(cat /tmp/err; dpkg -l | grep '^.i')"
[ "$(v sysx)" = "1 ii " ] && [ "$(v keepme)" = "1 ii " ] && [ "$(vs held)" = "1 hi " ] && ok "upgrade: what's held back and on hold are left" || bad "upgrade: left alone" "$(dpkg -l | grep '^.i')"
[ -z "$(v ofapp-old)" ] && [ "$(cat /var/lib/of-update/apps-removed)" = ofapp-old ] && ok "upgrade: the app it had to remove is gone, and named" ||
	bad "upgrade: the app removed" "$(cat /var/lib/of-update/apps-removed) $(v ofapp-old)"
[ -z "$(v oldlib)" ] && ok "upgrade: what upgrades left unused is removed" || bad "upgrade: unused removed" "$(v oldlib)"
grep -qx "state=installing" /run/of-update/state && grep -qx "percent=100" /run/of-update/state && grep -qx "kind=update" /run/of-update/state &&
	ok "upgrade: the state file says how it went, keeping the run's kind" || bad "upgrade: the state file" "$(cat /run/of-update/state)"

# Nothing left: an empty plan, and upgrade does nothing
"$H" plan 2>/tmp/err
[ ! -s "$L" ] && [ "$(cat "$HL")" = "$(printf 'sysx\tit would remove keepme')" ] && ok "plan again: only what's held back is left" || bad "plan again" "$(cat "$L" "$HL")"

# A download that's here already counts no bytes
mkpkg of keepme 2
publish
"$H" plan 2>/dev/null
apt-get download -qq keepme >/dev/null 2>&1 && mv keepme_2_all.deb /var/cache/apt/archives/
[ "$(line keepme | cut -f4)" != 0 ] && "$H" plan 2>/dev/null && [ "$(line keepme | cut -f4)" = 0 ] &&
	ok "plan: an update downloaded already counts no bytes" || bad "plan: downloaded already" "$(cat "$L")"

# A download that fails: exit 1, nothing installed
rm -f /var/cache/apt/archives/keepme_2_all.deb /repo/of/keepme_2_all.deb
"$H" upgrade >/dev/null 2>&1; r=$?
[ $r = 1 ] && [ "$(v keepme)" = "1 ii " ] && ok "upgrade: a download that fails exits 1, installing nothing" || bad "upgrade: a failed download" "r=$r $(v keepme)"

echo
[ "$FAILS" -eq 0 ] && echo "all passed" || echo "$FAILS failed"
exit "$FAILS"
