#!/bin/bash
# test_of_reset.sh: of-reset (overlay-debian-trixie/usr/local/sbin/of-reset), erasing an
# OpenFrame for its next owner, on a stand-in that's been lived in: "of" with a password,
# keys and files, another account, root's keys, Wi-Fi settings on OF-BOOT and in of-netplan's
# records, a network.yaml, a touch calibration, an app, and an update that brought in a new
# dependency. A dry run changes nothing; the real one leaves the image's packages (and what
# they need now), the calibration and the unit's MAC, takes the rest, and restarts. Offline,
# with stand-in packages, in an i386 Debian Trixie container (Docker) unless it's root in one:
#   bash tests/test_of_reset.sh
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
if [ "$(id -u)" -ne 0 ] || [ ! -e /.dockerenv ]; then
	exec docker run --rm --security-opt seccomp=unconfined --platform linux/386 -v "$HERE:/src:ro" \
		i386/debian:trixie bash /src/tests/test_of_reset.sh
fi
FAILS=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; [ -n "${2:-}" ] && sed 's/^/       /' <<< "$2" | tail -12; FAILS=$((FAILS + 1)); }
export DEBIAN_FRONTEND=noninteractive
O=/src/overlay-debian-trixie

# Stand-ins: systemctl, hostnamectl, journalctl and systemd-id128 (no systemd here), bootrw.
mkdir -p /stub /usr/lib/openframe /boot/settings /opt/sprite/share/sprite /var/lib/of-netplan /etc/netplan \
	/var/lib/sprite /var/lib/private/sprite-apps/clock /etc/apt/sources.list.d /etc/ssh
for c in systemctl hostnamectl journalctl; do printf '#!/bin/sh\necho "%s $*" >> /tmp/calls\n' "$c" > /stub/$c; done
printf '#!/bin/sh\nhead -c16 /dev/urandom | od -An -tx1 | tr -d " \\n"; echo\n' > /stub/systemd-id128
printf '#!/bin/sh\nexit 0\n' > /usr/lib/openframe/bootrw
chmod 755 /stub/* /usr/lib/openframe/bootrw
export PATH="/stub:$PATH"
install -m 755 $O/usr/local/sbin/of-reset /usr/local/sbin/of-reset

# Packages: img-a (needs dep-c) as the image had them, then an app, and an update to img-a
# that needs new-dep-d.
deb() { # name version [depends]
	d=/tmp/b-$1-$2; mkdir -p $d/DEBIAN
	printf 'Package: %s\nVersion: %s\nArchitecture: all\nMaintainer: t <t@t>\nDescription: test\n' "$1" "$2" > $d/DEBIAN/control
	[ -n "${3:-}" ] && echo "Depends: $3" >> $d/DEBIAN/control
	dpkg-deb --build --root-owner-group $d /tmp/$1_$2.deb >/dev/null
}
deb dep-c 1; deb img-a 1 dep-c; deb ofapp-clock 1; deb new-dep-d 1; deb img-a 2 "dep-c, new-dep-d"
dpkg -i /tmp/dep-c_1.deb /tmp/img-a_1.deb >/dev/null 2>&1
apt-mark auto dep-c >/dev/null
dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' | awk '$1 == "ii" { print $2 }' | sort -u > /usr/lib/openframe/image-packages
dpkg -i /tmp/ofapp-clock_1.deb /tmp/new-dep-d_1.deb /tmp/img-a_2.deb >/dev/null 2>&1
apt-mark auto new-dep-d >/dev/null

# Settings: the templates, and the owner's own
cp $O/boot/settings/*.txt /usr/lib/openframe/settings/ 2>/dev/null || { mkdir -p /usr/lib/openframe/settings; cp $O/boot/settings/*.txt /usr/lib/openframe/settings/; }
printf '## Sprite, the touch screen.\n\nstartup=\ncalibration=\n' > /opt/sprite/share/sprite/sprite.txt
cp /usr/lib/openframe/settings/*.txt /boot/settings/
sed -i 's/^name=.*/name=HomeWiFi/; s/^password=.*/password=secret-wifi-pass/' /boot/settings/wifi.txt
printf '## Sprite\n\nstartup=clock\ncalibration=1.01,0,-3,0,0.99,2\n' > /boot/settings/sprite.txt
echo "network: {}" > /boot/settings/network.yaml
echo "password=secret-wifi-pass" > /var/lib/of-netplan/wifi.txt
echo "02:0e:8e:24:cd:0a" > /var/lib/of-netplan/lan.mac
echo "wifis: secret-wifi-pass" > /etc/netplan/network.yaml
echo "0 0 2 1 4 5 7 8" > /var/lib/sprite/layout
echo data > /var/lib/private/sprite-apps/clock/state
echo "deb x trixie-testing main" > /etc/apt/sources.list.d/openframe-testing.list
touch /etc/ssh/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key.pub

# People
useradd -m -s /bin/bash of; echo 'of:joggler' | chpasswd
mkdir -p /home/of/.ssh; echo "ssh-ed25519 AAAA owner" > /home/of/.ssh/authorized_keys; echo notes > /home/of/notes.txt
useradd -m -s /bin/bash guest
mkdir -p /root/.ssh; echo "ssh-ed25519 AAAA root" > /root/.ssh/authorized_keys

snap() { { dpkg-query -W -f='${Package} ${Version}\n'; getent shadow of; ls -R /home /root /boot/settings /var/lib/sprite /etc/ssh; } 2>/dev/null | md5sum; }
before=$(snap)
out=$(of-reset --dry-run 2>&1)
[ "$(snap)" = "$before" ] && [ ! -s /tmp/calls ] && ok "a dry run changes nothing" || bad "a dry run changes nothing" "$out"
grep -q "ofapp-clock" <<< "$out" && ok "and says what it would remove" || bad "and says what it would remove" "$out"
of-reset >/dev/null 2>&1 && bad "without --yes it does nothing" || ok "without --yes it does nothing"

out=$(of-reset --yes 2>&1)
has() { dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | grep -q '^ii'; }
! has ofapp-clock && ok "the app is gone" || bad "the app is gone" "$out"
has img-a && has dep-c && ok "the image's packages stay" || bad "the image's packages stay" "$out"
has new-dep-d && ok "and what an update made them need" || bad "and what an update made them need" "$out"
[ "$(dpkg-query -W -f='${Version}' img-a)" = 2 ] && ok "updates stay" || bad "updates stay"
[ "$(getent shadow of | cut -d: -f2)" = '*' ] && ok "of has no password" || bad "of has no password" "$(getent shadow of)"
[ ! -e /home/of/.ssh ] && [ ! -e /home/of/notes.txt ] && [ -e /home/of/.bashrc ] && [ "$(stat -c %U /home/of/.bashrc)" = of ] &&
	ok "of's home is as new, its own" || bad "of's home is as new" "$(ls -la /home/of)"
! getent passwd guest >/dev/null && [ ! -e /home/guest ] && ok "other accounts go" || bad "other accounts go"
[ ! -e /root/.ssh ] && ok "root's keys go" || bad "root's keys go" "$(ls -la /root)"
[ -z "$(ls /etc/ssh/ssh_host_* 2>/dev/null)" ] && ok "the SSH host keys go (new ones at the next start)" || bad "the SSH host keys go"
cmp -s /boot/settings/wifi.txt /usr/lib/openframe/settings/wifi.txt && ! grep -rq secret-wifi-pass /boot/settings /var/lib/of-netplan /etc/netplan &&
	ok "the Wi-Fi password is nowhere" || bad "the Wi-Fi password is nowhere" "$(grep -r secret-wifi-pass /boot /var/lib/of-netplan /etc/netplan)"
[ ! -e /boot/settings/network.yaml ] && ok "the owner's own settings files go" || bad "the owner's own settings files go" "$(ls /boot/settings)"
grep -qx 'calibration=1.01,0,-3,0,0.99,2' /boot/settings/sprite.txt && grep -qx 'startup=' /boot/settings/sprite.txt &&
	ok "the touch calibration stays, the startup app goes" || bad "the touch calibration stays" "$(cat /boot/settings/sprite.txt)"
[ -e /var/lib/of-netplan/lan.mac ] && ok "the unit's MAC stays" || bad "the unit's MAC stays"
[ ! -e /var/lib/sprite/layout ] && [ ! -e /var/lib/private/sprite-apps ] && ok "the home screen and apps' data go" || bad "the home screen and apps' data go"
[ ! -e /etc/apt/sources.list.d/openframe-testing.list ] && grep -qx 'testing=no' /boot/settings/test.txt &&
	ok "not a test unit any more" || bad "not a test unit any more"
grep -qx '[0-9a-f]\{32\}' /etc/machine-id && ok "a new machine-id" || bad "a new machine-id" "$(cat /etc/machine-id)"
tail -1 /tmp/calls | grep -q "^systemctl reboot" && ok "and it restarts" || bad "and it restarts" "$(cat /tmp/calls)"

echo
[ "$FAILS" -eq 0 ] && echo "all passed" || echo "$FAILS failed"
exit "$FAILS"
