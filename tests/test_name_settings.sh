#!/bin/bash
# test_name_settings.sh: name-settings (overlay-debian-trixie/usr/lib/openframe/name-settings),
# which names the OpenFrame from OF-BOOT/settings/name.txt: the hostname is made from the name
# (lower case, accents off, apostrophes dropped, anything else a hyphen, at most 63, ends
# trimmed), /etc/hostname and /etc/hosts' 127.0.1.1 line follow it, and the name as written
# is kept as the pretty hostname in /etc/machine-info, with that file's other lines; an empty
# name (the template's) is openframe, with no pretty name; a name with control characters
# changes nothing; without name.txt nothing changes. It needs root and /boot, so it runs
# itself in a Debian Trixie container (Docker) unless it's root already:
#   bash tests/test_name_settings.sh
# Prints one line per case; exits non-zero if any case fails.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
if [ "$(id -u)" -ne 0 ] || [ ! -e /.dockerenv ]; then
	exec docker run --rm -v "$HERE:/src:ro" debian:trixie bash /src/tests/test_name_settings.sh
fi
FAILS=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; [ -n "${2:-}" ] && sed 's/^/       /' <<< "$2" | tail -12; FAILS=$((FAILS + 1)); }
S=/src/overlay-debian-trixie/usr/lib/openframe/name-settings
T=/src/overlay-debian-trixie/boot/settings/name.txt
N=/boot/settings/name.txt
mkdir -p /boot/settings
echo openframe > /etc/hostname
printf '127.0.0.1\tlocalhost\n127.0.1.1\topenframe\n::1\tlocalhost\n' > /etc/hosts
printf 'CHASSIS=embedded\n' > /etc/machine-info
pretty() { sed -n 's/^PRETTY_HOSTNAME=//p' /etc/machine-info 2>/dev/null; }

out=$(bash $S 2>&1)
[ "$(cat /etc/hostname)" = openframe ] && [ -z "$(pretty)" ] && ok "no name.txt: nothing changes" || bad "no name.txt: nothing changes" "$out"

# name value, then the hostname and pretty name it should give
check() {
	local what="$1" line="$2" host="$3" want_pretty="$4"
	cp "$T" $N
	printf '%s\n' "$line" >> $N
	out=$(bash $S 2>&1)
	if [ "$(cat /etc/hostname)" = "$host" ] && grep -qxP "127\.0\.1\.1\t$host" /etc/hosts && [ "$(pretty)" = "$want_pretty" ] &&
	   grep -qx CHASSIS=embedded /etc/machine-info && [ "$(grep -c '^127.0.1.1' /etc/hosts)" = 1 ]; then
		ok "$what"
	else
		bad "$what" "$out
hostname: $(cat /etc/hostname) / pretty: $(pretty)
$(cat /etc/hosts)"
	fi
}
check "a plain name: lower case, kept as written" "name=Kitchen" kitchen '"Kitchen"'
check "an apostrophe and a space" "name=Andy's Kitchen" andys-kitchen "\"Andy's Kitchen\""
check "accents off" "name=Café Nord" cafe-nord '"Café Nord"'
check "quotes taken off, spaces around kept out" '  NAME = "Den 2"  ' den-2 '"Den 2"'
check "nothing but the hostname: no pretty name" "name=hall" hall ""
check "shell characters kept safe" 'name=$HOME `x` "q" \b' home-x-q-b '"\$HOME \`x\` \"q\" \\b"'
check "at most 63, no hyphen at the end" "name=$(printf 'a%.0s' {1..62}) bcd" "$(printf 'a%.0s' {1..62})" "\"$(printf 'a%.0s' {1..62}) bcd\""
check "nothing usable: openframe" "name=!!!" openframe '"!!!"'
check "the last name= counts" $'name=First\nname=Second' second '"Second"'
check "empty: openframe, no pretty name" "name=" openframe ""

cp "$T" $N; printf 'name=Kitchen\n' >> $N; bash $S >/dev/null 2>&1
cp "$T" $N; printf 'name=Bad\001name\n' >> $N
out=$(bash $S 2>&1)
[ "$(cat /etc/hostname)" = kitchen ] && [ "$(pretty)" = '"Kitchen"' ] && grep -q "control characters" <<< "$out" &&
	ok "control characters: left as it was" || bad "control characters: left as it was" "$out"

echo
[ "$FAILS" -eq 0 ] && echo "all passed" || echo "$FAILS failed"
exit "$FAILS"
