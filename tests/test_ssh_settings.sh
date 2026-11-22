#!/bin/bash
# test_ssh_settings.sh: ssh-settings (overlay-debian-trixie/usr/lib/openframe/ssh-settings),
# which applies OF-BOOT/settings/ssh.txt: the password is set (spaces, quotes and
# backslashes kept) and then emptied in the file, with the rest of the file as it was;
# public keys go in a block of their own in authorized_keys, replacing the last ones from
# the file and leaving keys added by hand; lines that aren't keys are left out; with
# nothing in the file nothing changes; and on a flash stick the password stays in the
# file, for each unit the stick installs. It needs root, a user called "of" and /boot, so
# it runs itself in a Debian Trixie container (Docker) unless it's root already:
#   bash tests/test_ssh_settings.sh
# Prints one line per case; exits non-zero if any case fails.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
if [ "$(id -u)" -ne 0 ] || [ ! -e /.dockerenv ]; then
	exec docker run --rm -v "$HERE:/src:ro" debian:trixie bash /src/tests/test_ssh_settings.sh
fi

FAILS=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; [ -n "${2:-}" ] && sed 's/^/       /' <<< "$2" | tail -10; FAILS=$((FAILS + 1)); }

useradd -m -p '*' -s /bin/bash of
mkdir -p /boot/settings /usr/lib/openframe
printf '#!/bin/sh\nexit 0\n' > /usr/lib/openframe/bootrw # the boot volume is writable here
chmod 755 /usr/lib/openframe/bootrw
S=/usr/lib/openframe/ssh-settings
install -m 755 /src/overlay-debian-trixie/usr/lib/openframe/ssh-settings "$S"
T=/boot/settings/ssh.txt
K1="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKexampleexampleexampleexampleexample01 andy@mac"
K2="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQexample+example/example== other"
HAND="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIhandaddedhandaddedhandaddedhandadded by-hand"
hash() { getent shadow of | cut -d: -f2; }
# True if $1 is of's password (the hash, worked out again with its own salt).
is_pass() {
	local h salt
	h=$(hash)
	salt="${h%\$*}"
	[ "$(PW="$1" SALT="$salt" perl -e 'print crypt($ENV{PW}, $ENV{SALT})')" = "$h" ]
}
AK=/home/of/.ssh/authorized_keys

# The SSH server's condition: nobody can log in with no password and no key.
"$S" check >/dev/null 2>&1 && bad "check: nobody can log in at first" || ok "check: nobody can log in at first"

# Nothing set: nothing changes.
cp /src/overlay-debian-trixie/boot/settings/ssh.txt "$T"
before=$(hash)
out=$("$S" 2>&1)
[ "$(hash)" = "$before" ] && [ ! -e "$AK" ] && cmp -s "$T" /src/overlay-debian-trixie/boot/settings/ssh.txt &&
	ok "the template changes nothing" || bad "the template changes nothing" "$out"

# A password with spaces, quotes and a backslash, in double quotes, and a key.
PW='my "kitchen" \frame 2'
sed -i "s|^password=.*|password=\"$(printf '%s' "$PW" | sed 's/[\\&|]/\\&/g')\"|; s|^key=.*|key=$K1|" "$T"
cp "$T" /tmp/before.txt
out=$("$S" 2>&1)
is_pass "$PW" && ok "the password is set as written" || bad "the password is set as written" "$out"
grep -qx 'password=' "$T" && ! grep -q 'kitchen' "$T" && ok "the password is emptied in ssh.txt" ||
	bad "the password is emptied in ssh.txt" "$(cat "$T")"
diff <(grep -v '^password=' /tmp/before.txt) <(grep -v '^password=' "$T") >/dev/null &&
	ok "the rest of ssh.txt is as it was" || bad "the rest of ssh.txt is as it was" "$(diff /tmp/before.txt "$T")"
grep -qxF "$K1" "$AK" && [ "$(stat -c '%U %a' "$AK")" = "of 600" ] && [ "$(stat -c '%U %a' /home/of/.ssh)" = "of 700" ] &&
	ok "the key is in authorized_keys, of's own" || bad "the key is in authorized_keys, of's own" "$(ls -la /home/of/.ssh; cat "$AK")"

"$S" check >/dev/null 2>&1 && ok "check: of can log in with a password" || bad "check: of can log in with a password"

# Started again with the password emptied: it stays.
"$S" >/dev/null 2>&1
is_pass "$PW" && ok "an empty password= keeps the password" || bad "an empty password= keeps the password"

# A key added by hand stays; the file's keys are replaced; a line that isn't a key is left out.
echo "$HAND" >> "$AK"
sed -i "s|^key=.*|key=$K2\nkey=not a key at all\nKEY = '$K1'|" "$T"
out=$("$S" 2>&1)
grep -qxF "$HAND" "$AK" && grep -qxF "$K2" "$AK" && grep -qxF "$K1" "$AK" && ! grep -q 'not a key' "$AK" &&
	[ "$(grep -c '^ssh-' "$AK")" = 3 ] && ok "keys are replaced, hand-added ones kept, junk left out" ||
	bad "keys are replaced, hand-added ones kept, junk left out" "$(cat "$AK"; echo "$out")"
grep -q "isn't an SSH public key" <<< "$out" && ok "a line that isn't a key is reported" || bad "a line that isn't a key is reported" "$out"

# No keys in the file any more: its block goes, the hand-added key stays.
sed -i '/^key/Id' "$T"
echo 'key=' >> "$T"
"$S" >/dev/null 2>&1
grep -qxF "$HAND" "$AK" && ! grep -qxF "$K2" "$AK" && ! grep -q 'ssh.txt' "$AK" &&
	ok "emptied keys are taken out" || bad "emptied keys are taken out" "$(cat "$AK")"

# On a flash stick (it carries the image copy), the password is set but stays in the file,
# for OpenFrame Flash to copy to each unit it installs.
mkdir -p /usr/lib/openframe/flash && touch /usr/lib/openframe/flash/image.img.gz
printf 'password=for every unit\nkey=\n' > "$T"
out=$("$S" 2>&1)
is_pass "for every unit" && grep -qx 'password=for every unit' "$T" && grep -q 'flash stick' <<< "$out" &&
	ok "a flash stick keeps the password in ssh.txt" || bad "a flash stick keeps the password in ssh.txt" "$(cat "$T"; echo "$out")"
rm /usr/lib/openframe/flash/image.img.gz

# A password with a control character isn't set, and stays in the file to be put right.
printf 'password=bad\tpass\n' > "$T"
before=$(hash)
out=$("$S" 2>&1)
[ "$(hash)" = "$before" ] && grep -q 'control characters' <<< "$out" && ok "a control character is refused" ||
	bad "a control character is refused" "$out"

# The condition by key alone: of's, root's (whose password doesn't count), and not a
# system user's.
usermod -p '*' of
"$S" check >/dev/null 2>&1 && ok "check: of can log in with a key alone" || bad "check: of can log in with a key alone"
rm -f "$AK"
"$S" check >/dev/null 2>&1 && bad "check: no password and no key again" || ok "check: no password and no key again"
usermod -p "$(perl -e 'print crypt("rootpass", q($6$saltsalt$))')" root
"$S" check >/dev/null 2>&1 && bad "check: root's password doesn't count" || ok "check: root's password doesn't count"
mkdir -p /root/.ssh && echo "from=\"192.168.1.0/24\" $K1" > /root/.ssh/authorized_keys
"$S" check >/dev/null 2>&1 && ok "check: root's key (with options) counts" || bad "check: root's key (with options) counts"
rm -rf /root/.ssh
useradd -r -m -s /usr/sbin/nologin -p "$(perl -e 'print crypt("x", q($6$saltsalt$))')" svc
"$S" check >/dev/null 2>&1 && bad "check: a system user's password doesn't count" || ok "check: a system user's password doesn't count"

echo
[ "$FAILS" -eq 0 ] && echo "all passed" || echo "$FAILS failed"
exit "$FAILS"
