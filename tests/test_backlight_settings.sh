#!/bin/bash
# test_backlight_settings.sh: of-backlight's settings and set (overlay-debian-trixie/usr/
# local/bin/of-backlight), for Sprite's automatic brightness limits: settings prints the
# limits in use (the defaults without a file); set changes min, max and off_below in
# backlight.txt, uncommenting the template's lines, keeping every note and other setting,
# adding a key the file lacks, and refusing what isn't one of those or is out of range. It
# needs root and /boot, so it runs itself in a Debian Trixie container (Docker) unless it's
# root already:
#   bash tests/test_backlight_settings.sh
# Prints one line per case; exits non-zero if any case fails.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
if [ "$(id -u)" -ne 0 ] || [ ! -e /.dockerenv ]; then
	exec docker run --rm -v "$HERE:/src:ro" debian:trixie bash /src/tests/test_backlight_settings.sh
fi
FAILS=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; [ -n "${2:-}" ] && sed 's/^/       /' <<< "$2" | tail -12; FAILS=$((FAILS + 1)); }
B=/src/overlay-debian-trixie/usr/local/bin/of-backlight
T=/src/overlay-debian-trixie/boot/settings/backlight.txt
mkdir -p /boot/settings /usr/lib/openframe/settings
cp "$T" /usr/lib/openframe/settings/
printf '#!/bin/sh\nexit 0\n' > /usr/lib/openframe/bootrw; chmod 755 /usr/lib/openframe/bootrw
C=/boot/settings/backlight.txt

[ "$(bash $B settings | tr '\n' ' ')" = "min=0 max=100 off_below=1 " ] && ok "no file: the defaults" || bad "no file: the defaults" "$(bash $B settings)"
cp "$T" $C
bash $B set min=10 max=80 off_below=0 || bad "set runs"
[ "$(bash $B settings | tr '\n' ' ')" = "min=10 max=80 off_below=0 " ] && ok "set changes them" || bad "set changes them" "$(bash $B settings; cat $C)"
grep -qx "min=10" $C && ! grep -q "^#min=" $C && ok "the template's commented line is the one changed" || bad "the template's commented line is the one changed" "$(cat $C)"
[ "$(grep -v '^\(min\|max\|off_below\)=' $C)" = "$(grep -v '^#\(min\|max\|off_below\)=' "$T")" ] &&
	ok "every note and other setting stays" || bad "every note and other setting stays" "$(diff "$T" $C)"
bash $B set max=60
[ "$(grep -c '^max=' $C)" = 1 ] && grep -qx "max=60" $C && grep -qx "min=10" $C && ok "set again: one line, the rest kept" || bad "set again: one line, the rest kept" "$(cat $C)"
printf 'full=300\r\n' > $C
bash $B set off_below=0
grep -q "^full=300" $C && grep -qx "off_below=0" $C && ok "a key the file lacks goes at the end" || bad "a key the file lacks goes at the end" "$(cat -A $C)"
rm $C
bash $B set min=5
grep -qx "min=5" $C && grep -q "^## Automatic brightness" $C && ok "with no file, the template's, changed" || bad "with no file, the template's, changed" "$(cat $C)"
cp $C /tmp/before
for bad_arg in "max=101" "full=10" "min=abc" "min=-1" 'min=1;reboot'; do
	bash $B set "$bad_arg" >/dev/null 2>&1 && bad "refuses $bad_arg"
done
cmp -s $C /tmp/before && ok "refuses what isn't a limit, changing nothing" || bad "refuses what isn't a limit" "$(diff /tmp/before $C)"
bash $B set off_below=1000 >/dev/null && grep -qx "off_below=1000" $C && ok "off_below isn't a percentage" || bad "off_below isn't a percentage"

echo
[ "$FAILS" -eq 0 ] && echo "all passed" || echo "$FAILS failed"
exit "$FAILS"
