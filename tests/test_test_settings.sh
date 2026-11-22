#!/bin/bash
# test_test_settings.sh: test-settings (overlay-debian-trixie/usr/lib/openframe/test-settings),
# which applies OF-BOOT/settings/test.txt: testing=yes adds the OpenFrame repositories'
# testing suites (the unit's own lists, each suite with -testing, components and options
# kept), anything else takes them away, and the template changes nothing. It needs root and
# /etc/apt, so it runs itself in a Debian Trixie container (Docker) unless it's root already:
#   bash tests/test_test_settings.sh
# Prints one line per case; exits non-zero if any case fails.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
if [ "$(id -u)" -ne 0 ] || [ ! -e /.dockerenv ]; then
	exec docker run --rm -v "$HERE:/src:ro" debian:trixie bash /src/tests/test_test_settings.sh
fi

FAILS=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; [ -n "${2:-}" ] && sed 's/^/       /' <<< "$2" | tail -10; FAILS=$((FAILS + 1)); }

T=/usr/lib/openframe/test-settings
mkdir -p /usr/lib/openframe /boot/settings /etc/apt/sources.list.d
install -m 755 /src/overlay-debian-trixie/usr/lib/openframe/test-settings "$T"
D=/etc/apt/sources.list.d
echo "deb [signed-by=/etc/apt/keyrings/openframe-linux.gpg] https://linux.openbeak.net/ trixie main" > $D/openframe-linux.list
echo "deb [signed-by=/etc/apt/keyrings/openframe-kernel.gpg] https://kernel.openbeak.net/ trixie 6.18" > $D/openframe-kernel.list
echo "deb [signed-by=/etc/apt/keyrings/openframe-firmware.gpg] https://firmware.openbeak.net/ trixie main" > $D/openframe-firmware.list
L=$D/openframe-testing.list

cp /src/overlay-debian-trixie/boot/settings/test.txt /boot/settings/test.txt
"$T" >/dev/null
[ ! -e "$L" ] && ok "the template (testing=no) changes nothing" || bad "the template (testing=no) changes nothing" "$(cat "$L")"

sed -i 's/^testing=.*/ Testing = "Yes"\r/' /boot/settings/test.txt
out=$("$T")
want="deb [signed-by=/etc/apt/keyrings/openframe-linux.gpg] https://linux.openbeak.net/ trixie-testing main
deb [signed-by=/etc/apt/keyrings/openframe-kernel.gpg] https://kernel.openbeak.net/ trixie-testing 6.18
deb [signed-by=/etc/apt/keyrings/openframe-firmware.gpg] https://firmware.openbeak.net/ trixie-testing main"
[ "$(grep '^deb' "$L")" = "$want" ] && ok "testing=yes (any case, quoted, CRLF) adds the testing suites" ||
	bad "testing=yes (any case, quoted, CRLF) adds the testing suites" "$(cat "$L"; echo "$out")"
grep -q "a test unit" <<< "$out" && ok "and says so" || bad "and says so" "$out"
[ -z "$("$T")" ] && ok "unchanged, it says nothing the next time" || bad "unchanged, it says nothing the next time"
[ "$(stat -c %a "$L")" = 644 ] && ok "anyone can read the list (Sprite tells a test unit by it)" || bad "anyone can read the list" "$(stat -c %a "$L")"

sed -i 's/^.*esting.*=.*$/testing=no/' /boot/settings/test.txt
"$T" >/dev/null
[ ! -e "$L" ] && ok "testing=no takes them away" || bad "testing=no takes them away" "$(cat "$L")"
echo testing=yes > /boot/settings/test.txt; "$T" >/dev/null
rm /boot/settings/test.txt; "$T" >/dev/null
[ ! -e "$L" ] && ok "so does taking test.txt away" || bad "so does taking test.txt away"

echo
[ "$FAILS" -eq 0 ] && echo "all passed" || echo "$FAILS failed"
exit "$FAILS"
