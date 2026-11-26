#!/bin/bash
# test_of_update.sh: of-update (overlay-debian-trixie/usr/local/sbin/of-update), the automatic
# updates, against stand-ins for apt-get, of-update-apt and systemctl: a catch-up does
# nothing after a recent update and runs after an old one; everything is downloaded before
# anything is installed; nothing waiting means no downloads; failures are recorded;
# status says what Sprite needs; a restart waits while an update is being installed; "now"
# doesn't look again just after a look; the night's run restarts when one's needed; and the
# owner's time (updates.txt) sets the night timer.
# It needs root, /run and /var/lib, so it runs itself in a Debian Trixie container (Docker)
# unless it's root already:
#   bash tests/test_of_update.sh
# Prints one line per case; exits non-zero if any case fails.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
if [ "$(id -u)" -ne 0 ] || [ ! -e /.dockerenv ]; then
	exec docker run --rm -v "$HERE:/src:ro" debian:trixie bash /src/tests/test_of_update.sh
fi

FAILS=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; [ -n "${2:-}" ] && sed 's/^/       /' <<< "$2" | tail -10; FAILS=$((FAILS + 1)); }

U=/usr/local/sbin/of-update
install -m 755 /src/overlay-debian-trixie/usr/local/sbin/of-update "$U"
mkdir -p /stub
CALLS=/tmp/calls
# Stand-ins: each says it was called (and with what) in $CALLS. PENDING is how many updates
# of-update-apt's plan finds; UU_FAIL makes its downloads fail, INSTALL_FAIL its installing;
# UPDATE_FAIL makes the lists fail. (of-update-apt itself is tested against real apt in
# test_of_update_apt.sh.)
cat > /stub/apt-get <<'EOF'
#!/bin/bash
echo "apt-get $*" >> /tmp/calls
# BROKEN: a package half installed (apt-get check fails) until "-f install" puts it right;
# BROKEN_REMOVES: putting it right would remove a package
case " $* " in
	*" check "*) [ -e /tmp/BROKEN ] && { echo "E: Unmet dependencies."; exit 100; }; exit 0 ;;
	*" -s "*" -f install "*)
		[ -e /tmp/BROKEN_REMOVES ] && echo "Remv $(cat /tmp/BROKEN_REMOVES) [1]"
		echo "Inst openframe-scripts [1] (2 OpenFrame:trixie [all])"; exit 0 ;;
	*" -f install "*) rm -f /tmp/BROKEN; exit 0 ;;
	# KEPT_REMOVES: what installing a kept-back update would remove
	*" -s "*" install "*)
		[ -e /tmp/KEPT_REMOVES ] && echo "Remv $(cat /tmp/KEPT_REMOVES) [1]"
		echo "Inst ${*##* } [1] (2 OpenFrame:trixie [all])"; exit 0 ;;
	*" -y "*" install "*) for p in ${*##*install }; do printf '%s\t2\n' "$p" >> /tmp/INSTALLED; done; exit 0 ;;
	*" update "*)
		[ -e /tmp/UPDATE_FAIL ] && { echo "E: Failed to fetch http://deb.debian.org/dists/trixie/InRelease"
			echo "E: Some index files failed to download. They have been ignored, or old ones used instead."; exit 100; }
		[ -e /tmp/NO_TESTING ] && { echo "E: The repository 'https://kernel.openbeak.net trixie-testing Release' does not have a Release file."
			echo "E: Some index files failed to download. They have been ignored, or old ones used instead."; exit 100; }
		exit 0 ;;
	*" -s "*) # as apt prints them: the first is one of ours, the rest Debian's
		for i in $(seq 1 "$(cat /tmp/PENDING 2>/dev/null || echo 0)"); do
			if [ $i = 1 ]; then echo "Inst pkg$i [1] (2 OpenFrame Linux:trixie [all])"
			elif [ $i = 3 ] && [ -e /tmp/TIERS ]; then echo "Inst openframe-firmware [1] (2 OpenFrame:trixie [i386])"
			elif [ $i = 4 ] && [ -e /tmp/TIERS ]; then echo "Inst ofapp-clock [1] (2 OpenFrame Apps:trixie [all])"
			else echo "Inst pkg$i [1] (2 Debian:13.8/stable, Debian-Security:13/stable-security [i386]) []"; fi
		done
		[ -e /tmp/WITH_BASH ] && echo "Inst bash [1] ($(dpkg-query -W -f='${Version}' bash) Debian:13.8/stable [i386])" ;;
	*" --print-uris "*" download "*) # where a package comes from: a repository in /tmp/repo
		p="${*##* }"; echo "'file:///tmp/repo/pool/${p%%=*}_2_all.deb' ${p%%=*}_2_all.deb 1000 SHA256:x" ;;
	*" --print-uris "*)
		for i in $(seq 1 "$(cat /tmp/PENDING 2>/dev/null || echo 0)"); do echo "'http://x/pkg${i}_2_i386.deb' pkg${i}_2_i386.deb 1000 SHA256:x"; done ;;
esac
exit 0
EOF
cat > /stub/of-update-apt <<'EOF'
#!/bin/bash
echo "of-update-apt $* state=$(sed -n 's/^state=//p' /run/of-update/state)" >> /tmp/calls
L=/var/lib/of-update/pending.list H=/var/lib/of-update/held.list
mkdir -p /var/lib/of-update
# lists: as apt-get update --error-on=any said it (UPDATE_FAIL: unreachable; NO_TESTING: a testing suite not there yet), its percent in the state file
if [ "$1" = lists ]; then
	[ -e /tmp/UPDATE_FAIL ] && { echo "E: Failed to fetch http://deb.debian.org/dists/trixie/InRelease"
		echo "E: Some index files failed to download. They have been ignored, or old ones used instead."; exit 100; }
	[ -e /tmp/NO_TESTING ] && { echo "E: Failed to fetch https://kernel.openbeak.net/dists/trixie-testing/InRelease  404  Not Found"
		echo "E: Some index files failed to download. They have been ignored, or old ones used instead."; exit 100; }
	echo "percent=42" >> /run/of-update/state; cp /run/of-update/state /tmp/state-seen
	exit 0
fi
# The plan, as of-update-apt writes it: the first update one of ours, the rest Debian's (TIERS:
# the third the firmware, the fourth an app); UU_KEEP's held back when what it would remove
# (KEPT_REMOVES) isn't only apps
: > $L.new; : > $H.new
for i in $(seq 1 "$(cat /tmp/PENDING 2>/dev/null || echo 0)"); do
	p=pkg$i t=debian
	[ $i = 1 ] && t=openframe
	[ $i = 3 ] && [ -e /tmp/TIERS ] && p=openframe-firmware t=firmware
	[ $i = 4 ] && [ -e /tmp/TIERS ] && p=ofapp-clock t=apps
	if [ "$p" = "$(cat /tmp/UU_KEEP 2>/dev/null)" ] && [[ $(cat /tmp/KEPT_REMOVES) != ofapp-* ]]; then
		printf '%s\tit would remove %s\n' $p "$(cat /tmp/KEPT_REMOVES)" >> $H.new; continue
	fi
	printf '%s\t2\t%s\t1000\t%s_2_i386.deb\t1\tfile:///tmp/repo/pool/%s_2_all.deb\n' $p $t $p $p >> $L.new
done
[ -e /tmp/WITH_BASH ] && printf 'bash\t%s\tdebian\t0\tbash.deb\t1\t\n' "$(dpkg-query -W -f='${Version}' bash)" >> $L.new
mv $L.new $L; mv $H.new $H
[ "$1" = plan ] && exit 0
# (downloading, then installing, as of-update-apt sets them)
[ -s $L ] && sed -i 's/^state=.*/state=downloading/' /run/of-update/state
[ -e /tmp/UU_HOLD ] && sleep 3
[ -e /tmp/UU_FAIL ] && exit 1
[ -e /tmp/INSTALL_FAIL ] && exit 2
# installed: what was planned is in (the dpkg-query stand-in says so); an app it removed, said
[ -s $L ] && { cut -f1,2 $L > /tmp/INSTALLED; echo 0 > /tmp/PENDING; }
rm -f /var/lib/of-update/apps-removed
[ -e /tmp/UU_KEEP ] && [[ $(cat /tmp/KEPT_REMOVES) == ofapp-* ]] && cat /tmp/KEPT_REMOVES > /var/lib/of-update/apps-removed
exit 0
EOF
cat > /stub/dpkg-query <<'EOF'
#!/bin/bash
# After the stand-in unattended-upgrade has "installed" things (/tmp/INSTALLED: package, tab,
# version), their versions, as of-update asks for them; before, the real dpkg-query.
[ -s /tmp/INSTALLED ] || exec /usr/bin/dpkg-query "$@"
both=no
for n in "$@"; do case "$n" in *'${Package}'*) both=yes ;; esac; done
for n in "$@"; do
	case "$n" in -*) continue ;; esac
	if [ $both = yes ]; then grep "^$n	" /tmp/INSTALLED | sed "s/\$/	$(cat /tmp/STATUS 2>/dev/null || echo 'ii ')/"
	else grep "^$n	" /tmp/INSTALLED | cut -f2 | tr -d '\n'; fi
done
EOF
cat > /stub/systemctl <<'EOF'
#!/bin/bash
echo "systemctl $*" >> /tmp/calls
# FLASHING: OpenFrame Flash at work (a oneshot: activating)
[ "$*" = "show -p ActiveState --value of-flash.service" ] && { [ -e /tmp/FLASHING ] && echo activating || echo inactive; }
exit 0
EOF
cat > /stub/curl <<'EOF'
#!/bin/bash
# file:// only (the container has no curl): -o <file> <url>
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
src="${url#file://}"; [ -f "$src" ] || exit 22; cp "$src" "$out"
EOF
cat > /stub/timeout <<'EOF'
#!/bin/bash
shift; exec "$@"
EOF
chmod 755 /stub/*
export PATH="/stub:$PATH" OF_UPDATE_APT=/stub/of-update-apt
STATUS=/var/lib/of-update/status
reset() { rm -f /tmp/calls /tmp/PENDING /tmp/UU_FAIL /tmp/INSTALL_FAIL /tmp/UPDATE_FAIL /tmp/UU_HOLD /tmp/WITH_BASH /tmp/INSTALLED /tmp/STATUS /tmp/TIERS /run/reboot-required /run/reboot-required.pkgs; touch /tmp/calls
	# (the last look long ago: "now" looks again)
	[ -f "$STATUS" ] && sed -i "s/^checked=.*/checked=1/" "$STATUS"; }
field() { "$U" status | sed -n "s/^$1=//p"; }

# Nothing waiting: the lists, no downloads, a good run recorded.
reset
"$U" run night >/dev/null 2>&1
[ "$(field result)" = ok ] && [ -n "$(field last)" ] && [ "$(field pending)" = 0 ] && [ ! -s /tmp/INSTALLED ] &&
	ok "nothing waiting: no downloads, a good run" || bad "nothing waiting: no downloads, a good run" "$(cat /tmp/calls; "$U" status)"
[ "$(field state)" = idle ] && ok "idle afterwards" || bad "idle afterwards" "$("$U" status)"

# A catch-up just after: nothing at all.
reset
"$U" run catchup >/dev/null 2>&1
# (but ask apt whether anything's half installed, which changes nothing)
[ -z "$(grep -v '^apt-get check ' /tmp/calls)" ] && ok "a catch-up after a recent update does nothing" || bad "a catch-up after a recent update does nothing" "$(cat /tmp/calls)"

# A day later: it runs, downloads before installing, and the count goes to 0.
reset
sed -i "s/^last=.*/last=$(( $(date +%s) - 25 * 3600 ))/" "$STATUS"
echo 3 > /tmp/PENDING
"$U" run catchup >/dev/null 2>&1
grep -q "^of-update-apt lists" /tmp/calls && ok "an old update is caught up" || bad "an old update is caught up" "$(cat /tmp/calls)"
[ "$(grep of-update-apt /tmp/calls)" = "$(printf 'of-update-apt lists state=checking\nof-update-apt upgrade state=preparing')" ] && [ "$(wc -l < /tmp/INSTALLED)" = 3 ] &&
	ok "the lists, then worked out, downloaded and installed in one go" || bad "the lists, then worked out, downloaded and installed in one go" "$(cat /tmp/calls)"
[ "$(field pending)" = 0 ] && [ "$(field result)" = ok ] && (( $(date +%s) - $(field last) < 60 )) &&
	ok "and the run is recorded" || bad "and the run is recorded" "$("$U" status)"
grep -q "apt-get clean" /tmp/calls && ok "the downloads are cleared away" || bad "the downloads are cleared away" "$(cat /tmp/calls)"

# Not while OpenFrame Flash is at work.
rm -f /tmp/calls; touch /tmp/FLASHING
"$U" run now >/dev/null 2>&1
rm -f /tmp/FLASHING
! grep -q "of-update-apt" /tmp/calls &&
	ok "no update while OpenFrame Flash is at work" || bad "no update while OpenFrame Flash is at work" "$(cat /tmp/calls)"

# Unreachable servers, and updates that don't install: recorded, the last good run kept.
reset
LAST=$(field last)
touch /tmp/UPDATE_FAIL
sed -i 's/sleep 60/sleep 0/' "$U" # (no waiting between tries here)
"$U" run now >/dev/null 2>&1 && bad "unreachable servers fail" || ok "unreachable servers fail"
[ "$(field result)" = failed ] && [ "$(field message)" = "the update servers couldn't be reached" ] && [ "$(field last)" = "$LAST" ] &&
	ok "and say so, keeping the last good run" || bad "and say so, keeping the last good run" "$("$U" status)"
[ "$(grep -c "^of-update-apt lists" /tmp/calls)" = 3 ] && ok "after three tries" || bad "after three tries" "$(cat /tmp/calls)"
reset
echo 2 > /tmp/PENDING
touch /tmp/UU_FAIL
"$U" run now >/dev/null 2>&1
[ "$(field result)" = failed ] && [ "$(field state)" = idle ] && [ "$(field message)" = "the updates couldn't all be downloaded" ] &&
	ok "a failed download is recorded, and it's idle again" || bad "a failed download is recorded, and it's idle again" "$("$U" status)"
reset
echo 2 > /tmp/PENDING
touch /tmp/INSTALL_FAIL
"$U" run now >/dev/null 2>&1
[ "$(field result)" = failed ] && [ "$(field message)" = "some updates didn't install" ] && [ "$(field pending)" = 2 ] &&
	ok "a failed install is recorded, the updates still waiting" || bad "a failed install is recorded, the updates still waiting" "$("$U" status)"
reset
"$U" run now >/dev/null 2>&1
[ "$(field result)" = ok ] && [ -z "$(field message)" ] && ok "a good run clears the failure" || bad "a good run clears the failure" "$("$U" status)"

# An update unpacked but not configured yet is half in: partial=, not done.
reset
echo 1 > /tmp/PENDING
"$U" check >/dev/null 2>&1
cut -f1,2 /var/lib/of-update/pending.list > /tmp/INSTALLED
echo "iU " > /tmp/STATUS
[ "$("$U" status | sed -n 's/^partial=//p')" = 1 ] && "$U" status | grep -q '^item=pkg1 2 openframe 0 ' && "$U" status | grep -qx 'now=pkg1' &&
	ok "an unpacked update is half in" || bad "an unpacked update is half in" "$("$U" status)"
echo "ii " > /tmp/STATUS
[ "$("$U" status | sed -n 's/^partial=//p')" = 0 ] && "$U" status | grep -q '^item=pkg1 2 openframe 1 ' &&
	ok "and configured, it's in" || bad "and configured, it's in" "$("$U" status)"
rm -f /tmp/STATUS

# A testing suite that isn't there yet (a test unit before its repository's first testing
# publish) doesn't stop the rest.
reset
touch /tmp/NO_TESTING
"$U" check >/dev/null 2>&1 && [ "$(field result)" != failed ] && ok "a missing testing suite doesn't stop an update" ||
	bad "a missing testing suite doesn't stop an update" "$("$U" status)"
rm -f /tmp/NO_TESTING

# check: the lists and the count, nothing installed.
reset
echo 5 > /tmp/PENDING
"$U" check >/dev/null 2>&1
[ "$(field pending)" = 5 ] && ! grep -q "of-update-apt upgrade" /tmp/calls && ok "check counts without installing" || bad "check counts without installing" "$(cat /tmp/calls; "$U" status)"

# The list: each update, ours or Debian's, and whether it's in yet.
items=$("$U" status | sed -n 's/^item=//p')
[ "$(sed -n 1p <<< "$items")" = "pkg1 2 openframe 0 1" ] && [ "$(sed -n 2p <<< "$items")" = "pkg2 2 debian 0 1" ] && [ "$(wc -l <<< "$items")" = 5 ] &&
	ok "status lists the updates, ours marked" || bad "status lists the updates, ours marked" "$items"
reset
echo 5 > /tmp/PENDING
touch /tmp/TIERS
"$U" check >/dev/null 2>&1
items=$("$U" status | sed -n 's/^item=//p' | cut -d' ' -f1,3 | tr '\n' ,)
[ "$items" = "pkg1 openframe,pkg2 debian,openframe-firmware firmware,ofapp-clock apps,pkg5 debian," ] &&
	ok "the firmware and apps are tiers of their own" || bad "the firmware and apps are tiers of their own" "$items"
[ "$(field firmware)" = no ] && echo openframe-firmware > /run/reboot-required.pkgs && [ "$(field firmware)" = pending ] &&
	ok "status says when firmware will be flashed" || bad "status says when firmware will be flashed" "$("$U" status)"
reset
echo 1 > /tmp/PENDING
touch /tmp/WITH_BASH
"$U" check >/dev/null 2>&1
[ "$("$U" status | sed -n 's/^item=bash //p' | cut -d' ' -f3)" = 1 ] && ok "an update that's in is marked done" ||
	bad "an update that's in is marked done" "$("$U" status; cat /var/lib/of-update/pending.list)"

# What's new: the notes for a waiting update of ours, from its repository's news/, newer
# than the version in and no newer than the one waiting; Debian's get none.
reset
mkdir -p /tmp/repo/news
printf '3\tNot this one: newer than the update\n2\tNew in two\n2\tAlso in two\n1\tAlready in\n' > /tmp/repo/news/pkg1.news
printf 'pkg1\t1\n' > /tmp/INSTALLED
echo 2 > /tmp/PENDING
"$U" check >/dev/null 2>&1
news=$("$U" news)
[ "$(grep -c '^part=' <<< "$news")" = 1 ] && grep -qx 'part=pkg1 2 openframe' <<< "$news" &&
	ok "news names our waiting updates, not Debian's" || bad "news names our waiting updates, not Debian's" "$news"
[ "$(grep '^news=' <<< "$news" | cut -f2- | tr '\t\n' ':|')" = "2:New in two|2:Also in two|" ] &&
	ok "with the notes between the version in and the one waiting, in order" ||
	bad "with the notes between the version in and the one waiting, in order" "$news"
rm -rf /tmp/repo/news
"$U" check >/dev/null 2>&1
[ "$("$U" news | grep -c '^news=')" = 2 ] && ok "notes already fetched stay if the next fetch fails" ||
	bad "notes already fetched stay if the next fetch fails" "$("$U" news)"

# A restart: none needed, none; needed, yes; needed while installing, not yet.
reset
"$U" reboot >/dev/null 2>&1
! grep -q reboot /tmp/calls && ok "no restart unless one's needed" || bad "no restart unless one's needed" "$(cat /tmp/calls)"
echo linux-image-x > /run/reboot-required.pkgs; touch /run/reboot-required
[ "$(field restart)" = yes ] && ok "status says a restart is needed" || bad "status says a restart is needed" "$("$U" status)"
"$U" reboot >/dev/null 2>&1
grep -q "^systemctl reboot" /tmp/calls && ok "a needed restart happens" || bad "a needed restart happens" "$(cat /tmp/calls)"
reset
touch /run/reboot-required /tmp/UU_HOLD
echo 1 > /tmp/PENDING
"$U" run now >/dev/null 2>&1 &
RUN=$!
sleep 1.5
[ "$(field state)" = installing ] || [ "$(field state)" = downloading ] && ok "status shows the update while it runs" ||
	bad "status shows the update while it runs" "$("$U" status)"
"$U" reboot >/dev/null 2>&1
! grep -q "^systemctl reboot" /tmp/calls && ok "but not while an update is being installed" || bad "but not while an update is being installed" "$(cat /tmp/calls)"
"$U" after poweroff >/dev/null 2>&1 # waits for it
wait $RUN
tail -1 /tmp/calls | grep -q "^systemctl poweroff" && grep -q "of-update-apt upgrade" /tmp/calls &&
	ok "'after poweroff' waits for the update, then switches off" || bad "'after poweroff' waits for the update, then switches off" "$(cat /tmp/calls)"

# "now" just after a look: no second look, straight to getting ready.
reset
"$U" check >/dev/null 2>&1
: > /tmp/calls
echo 1 > /tmp/PENDING
"$U" run now >/dev/null 2>&1
! grep -q "^of-update-apt lists" /tmp/calls && grep -q "of-update-apt upgrade" /tmp/calls &&
	ok "Update now just after Check now doesn't look again" || bad "Update now just after Check now doesn't look again" "$(cat /tmp/calls)"
grep -q "state=checking" /tmp/calls && bad "and never says it's checking" "$(cat /tmp/calls)" || ok "and never says it's checking"

# ... unless the sources have changed since the look (made a test unit just now): it looks again.
reset
"$U" check >/dev/null 2>&1
sleep 1
mkdir -p /tmp/apt/sources.list.d; touch /tmp/apt/sources.list.d/openframe-testing.list
: > /tmp/calls
OF_UPDATE_APTSOURCES=/tmp/apt "$U" run now >/dev/null 2>&1
grep -q "^of-update-apt lists" /tmp/calls && ok "Update now looks again if the sources changed since Check now" ||
	bad "Update now looks again if the sources changed since Check now" "$(cat /tmp/calls)"
rm -rf /tmp/apt

# Half installed (a power cut part way, a full disk): a check says so (never "up to date"),
# Update now puts it right when that only takes installing, and leaves it when it would
# remove a package, saying so.
reset
touch /tmp/BROKEN
"$U" check >/dev/null 2>&1
[ "$("$U" status | sed -n 's/^result=//p')" = failed ] && "$U" status | grep -q '^message=.*half done: trying again puts it right' &&
	ok "a check finds a package half installed: it says so, and that trying again puts it right" || bad "a check finds a package half installed" "$("$U" status)"
: > /tmp/calls
"$U" run now >/dev/null 2>&1
grep -q "^apt-get -y -q .* -f install" /tmp/calls && [ ! -e /tmp/BROKEN ] && [ "$("$U" status | sed -n 's/^result=//p')" = ok ] &&
	ok "Update now puts it right (installing what it needs), and carries on" || bad "Update now puts it right" "$(cat /tmp/calls; "$U" status)"
reset
touch /tmp/BROKEN; echo openframe-scripts > /tmp/BROKEN_REMOVES
: > /tmp/calls
"$U" run now >/dev/null 2>&1
! grep -q "^apt-get -y -q .* -f install" /tmp/calls && [ "$("$U" status | sed -n 's/^result=//p')" = failed ] &&
	"$U" status | grep -q "^message=.*can't be put right by itself (it would remove openframe-scripts)" &&
	ok "but not when that would remove a system package: left, and said what" || bad "a fix that would remove a package" "$(cat /tmp/calls; "$U" status)"
reset
touch /tmp/BROKEN; echo ofapp-clock > /tmp/BROKEN_REMOVES
: > /tmp/calls
"$U" run now >/dev/null 2>&1
grep -q "^apt-get -y -q .* -f install" /tmp/calls && [ "$("$U" status | sed -n 's/^result=//p')" = ok ] &&
	"$U" status | grep -q "^notice=clock had to be removed to finish an update" &&
	ok "an app may be removed to put it right: done, and the app named" || bad "a fix removing an app" "$(cat /tmp/calls; "$U" status)"
rm -f /tmp/BROKEN /tmp/BROKEN_REMOVES

# An update that needs another package removed: never left as "1 update waiting" for ever.
# Installed if all it needs removed is an app; otherwise said why.
reset
echo 2 > /tmp/PENDING; echo pkg2 > /tmp/UU_KEEP; echo openframe-scripts > /tmp/KEPT_REMOVES
"$U" run now >/dev/null 2>&1
[ "$(field result)" = failed ] && field message | grep -q "^1 update can't be installed by itself: pkg2 (it would remove openframe-scripts)" &&
	! grep -q "^apt-get -y -q .* install pkg2" /tmp/calls &&
	ok "an update kept back that would remove a system package: said, with why, never done" || bad "a kept-back update" "$(cat /tmp/calls; "$U" status)"
reset
echo 2 > /tmp/PENDING; echo pkg2 > /tmp/UU_KEEP; echo ofapp-radio > /tmp/KEPT_REMOVES
"$U" run now >/dev/null 2>&1
grep -q "of-update-apt upgrade" /tmp/calls && grep -qx "pkg2	2" /tmp/INSTALLED && [ "$(field result)" = ok ] && [ "$(field pending)" = 0 ] &&
	field notice | grep -q "^radio had to be removed" &&
	ok "one that would remove only an app: installed, and the app named" || bad "a kept-back update removing an app" "$(cat /tmp/calls; "$U" status)"
rm -f /tmp/UU_KEEP /tmp/KEPT_REMOVES
# Left alone: the catch-up after a start puts it right, however recent the last update.
reset
"$U" run now >/dev/null 2>&1   # a good update just now: a catch-up would do nothing
touch /tmp/BROKEN
: > /tmp/calls
"$U" run catchup >/dev/null 2>&1
grep -q "^apt-get -y -q .* -f install" /tmp/calls && [ ! -e /tmp/BROKEN ] &&
	ok "left alone: the catch-up after a start puts it right, though the last update was recent" || bad "the catch-up puts it right" "$(cat /tmp/calls)"
rm -f /tmp/BROKEN

# The night's run restarts when an update needs it, even one from earlier, and even if it fails.
reset
"$U" run night >/dev/null 2>&1
! grep -q "^systemctl reboot" /tmp/calls && ok "the night's run: no restart unless one's needed" || bad "the night's run: no restart unless one's needed" "$(cat /tmp/calls)"
reset
echo linux-image-x > /run/reboot-required.pkgs; touch /run/reboot-required
"$U" run night >/dev/null 2>&1
tail -1 /tmp/calls | grep -q "^systemctl reboot" && ok "the night's run restarts for an earlier update" || bad "the night's run restarts for an earlier update" "$(cat /tmp/calls)"
reset
touch /run/reboot-required /tmp/UPDATE_FAIL
"$U" run night >/dev/null 2>&1
tail -1 /tmp/calls | grep -q "^systemctl reboot" && ok "and when the servers can't be reached" || bad "and when the servers can't be reached" "$(cat /tmp/calls)"
reset
touch /run/reboot-required
"$U" run now >/dev/null 2>&1
! grep -q "^systemctl reboot" /tmp/calls && ok "Update now doesn't restart by itself" || bad "Update now doesn't restart by itself" "$(cat /tmp/calls)"

# The owner's time: updates.txt sets the night timer (a drop-in, none for the default).
reset
mkdir -p /boot/settings /usr/lib/openframe/settings
cp /src/overlay-debian-trixie/boot/settings/updates.txt /usr/lib/openframe/settings/
printf '#!/bin/sh\nexit 0\n' > /usr/lib/openframe/bootrw; chmod 755 /usr/lib/openframe/bootrw
DROP=/etc/systemd/system/of-update-night.timer.d/time.conf
"$U" schedule >/dev/null 2>&1
[ ! -e "$DROP" ] && [ "$(field time)" = 03:00 ] && ok "no updates.txt: 03:00, no drop-in" || bad "no updates.txt: 03:00, no drop-in" "$(cat "$DROP" 2>&1)"
for v in "time=11" "time = 11:00" "TIME=11:00\r"; do
	printf "$v\n" > /boot/settings/updates.txt
	[ "$(field time)" = 11:00 ] || bad "'$v' reads as 11:00" "$(field time)"
done
ok "the time reads however it's written"
printf 'time=25:00\n' > /boot/settings/updates.txt
[ "$(field time)" = 03:00 ] && ok "a time that isn't one: 03:00" || bad "a time that isn't one: 03:00" "$(field time)"
: > /tmp/calls
"$U" set-time 11:00 >/dev/null 2>&1
grep -qx "time=11:00" /boot/settings/updates.txt && grep -qx "OnCalendar=\*-\*-\* 11:00:00" "$DROP" &&
	grep -q "try-restart of-update-night.timer" /tmp/calls && ok "set-time writes updates.txt and moves the timer" ||
	bad "set-time writes updates.txt and moves the timer" "$(cat /boot/settings/updates.txt "$DROP" /tmp/calls)"
: > /tmp/calls
"$U" schedule >/dev/null 2>&1
[ ! -s /tmp/calls ] && ok "unchanged: the timer's left alone" || bad "unchanged: the timer's left alone" "$(cat /tmp/calls)"
rm /boot/settings/updates.txt
"$U" set-time 15:00 >/dev/null 2>&1
grep -qx "time=15:00" /boot/settings/updates.txt && grep -q "^## Updates" /boot/settings/updates.txt &&
	ok "with no updates.txt, set-time writes the template's" || bad "with no updates.txt, set-time writes the template's" "$(cat /boot/settings/updates.txt)"
"$U" set-time 03:00 >/dev/null 2>&1
[ ! -e "$DROP" ] && ok "back to 03:00: the drop-in goes" || bad "back to 03:00: the drop-in goes"
"$U" set-time 3pm >/dev/null 2>&1 && bad "set-time refuses what isn't a time" || ok "set-time refuses what isn't a time"

# What's held back counts as waiting, so Check now says so (and Update now says why).
reset
echo 2 > /tmp/PENDING; echo pkg2 > /tmp/UU_KEEP; echo openframe-scripts > /tmp/KEPT_REMOVES
"$U" check >/dev/null 2>&1
[ "$(field pending)" = 2 ] && [ "$("$U" status | grep -c '^item=')" = 1 ] &&
	ok "a held-back update counts as waiting, though it isn't listed" || bad "a held-back update counts as waiting" "$("$U" status)"
rm -f /tmp/UU_KEEP /tmp/KEPT_REMOVES

# How it's going: the lists' percent from apt's own count, and of-update-apt's percent, bytes and package, passed on while a run holds the lock.
reset
"$U" check >/dev/null 2>&1
grep -qx "state=checking" /tmp/state-seen && grep -qx "percent=42" /tmp/state-seen && grep -qx "kind=check" /tmp/state-seen &&
	ok "checking shows apt's percent, as a check" || bad "checking shows apt's percent, as a check" "$(cat /tmp/state-seen)"
echo 1 > /tmp/PENDING; "$U" check >/dev/null 2>&1
( flock 8; sleep 3 ) 8>/run/of-update.lock &
sleep 0.3
printf 'state=downloading\nsince=1\nkind=update\npercent=40\ngot=400\nsize=1000\n' > /run/of-update/state
st=$("$U" status)
grep -qx "percent=40" <<< "$st" && grep -qx "got=400" <<< "$st" && grep -qx "size=1000" <<< "$st" && grep -qx "kind=update" <<< "$st" &&
	ok "downloading: of-update-apt's percent and bytes" || bad "downloading: of-update-apt's percent and bytes" "$st"
printf 'state=installing\nsince=1\nkind=update\npercent=73\nnow=pkg1\n' > /run/of-update/state
st=$("$U" status)
grep -qx "percent=73" <<< "$st" && grep -qx "now=pkg1" <<< "$st" && ok "installing: apt's percent and the package going in" || bad "installing: apt's percent and the package going in" "$st"
wait

# A state left by a run that was killed doesn't stick.
printf 'state=installing\nsince=1\n' > /run/of-update/state
[ "$(field state)" = idle ] && ok "a stale state reads as idle" || bad "a stale state reads as idle" "$("$U" status)"

echo
[ "$FAILS" -eq 0 ] && echo "all passed" || echo "$FAILS failed"
exit "$FAILS"
