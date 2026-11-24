#!/bin/bash
# test_flash_backup.sh: OpenFrame Flash's backup= setting and a stick in use as a system
# (overlay-debian-trixie/usr/lib/openframe/flash/flash, and of-expand's reading of
# flash.txt): how flash.txt is read; the backup step with backup=no (the firmware only)
# and with too little room; where the units' folders go without OF-BACKUP; and that a
# stick in use as a system starts its own system, rather than holding the panel or
# switching off, when there's nothing for it to do. Nothing real is touched: the flash's
# functions are loaded without its main part, with its paths in a directory of its own,
# the firmware chip a file, and the panel, sounds and power-off stood in for. Run on
# Linux, as any user:
#   bash tests/test_flash_backup.sh [path to flash] [path to of-expand]
# Prints one line per case; exits non-zero if any case fails.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${1:-$HERE/../overlay-debian-trixie/usr/lib/openframe/flash/flash}
EXPAND=${2:-$HERE/../overlay-debian-trixie/usr/local/sbin/of-expand}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
FAILS=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; [ -n "${2:-}" ] && sed 's/^/       /' <<< "$2" | tail -16; FAILS=$((FAILS + 1)); }

# The flash without its main part (from its root check on).
sed '/^if \[ "\$(id -u)" -ne 0 \]; then$/,$d' "$SRC" > "$T/lib.sh"
grep -q '^backup_mode() {' "$T/lib.sh" || { echo "FAIL: no backup_mode in $SRC"; exit 1; }
# of-expand's flash.txt readers, with its flash.txt path made the test's.
sed -n '/^flash_setting() {/,/^}/p; /^install_mode() /p; /^backup_mode() {/,/^}/p' "$EXPAND" |
	sed "s#/boot/settings/flash.txt#$T/settings/flash.txt#" > "$T/expand.sh"

# A shell with the flash's functions loaded and its paths in $T.
cat > "$T/env.sh" <<EOF
. "$T/lib.sh"
SETDIR="$T/settings"; FLASHTXT="\$SETDIR/flash.txt"; STATEDIR="$T/state"; BACKUPMNT="$T/of-backup"
TTY="$T/tty"; RUNDIR="$T/run"; HOLD="\$RUNDIR/hold"; FHDEV="$T/chip.bin"; MMC="$T/mmc"
BUNDLEINFO="$T/info"; OF_FLASH_TEST_NOPOWEROFF=1
sound() { :; }; console_hush() { :; }; console_restore() { :; }; plymouth() { false; }
countdown() { echo "COUNTDOWN \$2"; }; power_off() { echo "POWEROFF"; }
lan_mac() { echo 02:00:00:00:00:01; }; clock_floor() { :; }
EOF
mkdir -p "$T/settings"
head -c 1048576 /dev/urandom > "$T/chip.bin"
echo "name=test-image" > "$T/info"

# How flash.txt is read: by the flash, and by of-expand alike.
setting() {    # setting <name> <flash.txt contents> <want backup_mode> [want install_mode]
	local name=$1 txt=$2 want=$3 wantf=${4:-} got gotf gote
	printf '%b' "$txt" > "$T/settings/flash.txt"
	got=$(bash -c ". '$T/env.sh'; backup_mode")
	gotf=$(bash -c ". '$T/env.sh'; install_mode")
	gote=$(bash -c ". '$T/expand.sh'; backup_mode")
	if [ "$got" = "$want" ] && [ "$gote" = "$want" ] && { [ -z "$wantf" ] || [ "$gotf" = "$wantf" ]; }; then
		ok "flash.txt $name: backup=$got${wantf:+, flash=$gotf}"
	else
		bad "flash.txt $name: backup=$got (of-expand $gote), flash=$gotf; want backup=$want${wantf:+, flash=$wantf}"
	fi
}
setting "without a backup line"        'flash=yes\n'                     yes yes
setting "backup=no"                    'flash=yes\nbackup=no\n'          no  yes
setting "Windows line ends, capitals"  'Flash = Again\r\nBackup = NO\r\n' no  again
setting "quoted off"                   'flash=no\nbackup="off"\n'        no  no
setting "backup=0"                     'backup=0\n'                      no
setting "backup=yes"                   'flash=yes\nbackup=yes\n'         yes yes
setting "the last line counts"         'backup=no\nbackup=yes\n'         yes
setting "a comment isn't a setting"    '# backup=no\nflash=yes\n'        yes yes
setting "no flash.txt at all"          ''                                yes
rm -f "$T/settings/flash.txt"
got=$(bash -c ". '$T/env.sh'; backup_mode")
[ "$got" = yes ] && ok "flash.txt missing: backup=yes" || bad "flash.txt missing: backup=$got"

# The backup step with backup=no: the firmware only, read twice and kept, and the unit
# marked backed up.
rm -rf "$T/unit" "$T/w"; mkdir -p "$T/unit" "$T/w"; echo "state=new" > "$T/unit/info.txt"
printf 'flash=yes\nbackup=no\n' > "$T/settings/flash.txt"
out=$(bash -c ". '$T/env.sh'; MODE=cli; W='$T/w'; UDIR='$T/unit'; use_backup_setting; backup; echo BACKUP-RETURNED" 2>&1)
I="$T/unit/info.txt"
if grep -q BACKUP-RETURNED <<< "$out" && grep -qx "state=backed-up" "$I" && grep -qx "mmc_backup=none (backup=no)" "$I" &&
   cmp -s "$T/chip.bin" "$T/unit/firmware.bin" && [ -s "$T/unit/firmware.bin.md5" ] && [ ! -e "$T/unit/mmc.img.gz" ] &&
   ! ls "$T/unit"/mmc.img.gz* >/dev/null 2>&1; then
	ok "backup=no: the firmware backed up, the internal memory not, state backed-up"
else
	bad "backup=no: $(ls "$T/unit" | paste -sd ' ' -); $(grep -E '^(state|mmc_backup)=' "$I" | paste -sd ' ' -)" "$out"
fi
grep -q "not the internal memory" <<< "$out" && ok "backup=no: it says so" || bad "backup=no: it didn't say so" "$out"

# The panel's first step and its times with backup=no; as before without it.
got=$(bash -c ". '$T/env.sh'; use_backup_setting >/dev/null; echo \"\${STEPS[0]}|\${PH_EST[mmcbackup]}|\${PH_EST[verify]}|\$MMC_SKIP\"")
[ "$got" = "Back up the firmware|0|0|1" ] && ok "backup=no: the panel's first step is the firmware's" || bad "backup=no: panel step $got"
printf 'flash=yes\n' > "$T/settings/flash.txt"
got=$(bash -c ". '$T/env.sh'; use_backup_setting >/dev/null; echo \"\${STEPS[0]}|\${PH_EST[mmcbackup]}|\$MMC_SKIP\"")
[ "$got" = "Back up what's there|80|" ] && ok "backup=yes: the panel as before" || bad "backup=yes: panel step $got"

# Too little room: stopped, with backup=no suggested when the internal memory was to be
# backed up; with backup=no, stopped plainly (its few MB weren't there either).
room() {    # room <name> <flash.txt> <want the hint: yes|no>
	rm -rf "$T/unit" "$T/w"; mkdir -p "$T/unit" "$T/w"; echo "state=new" > "$T/unit/info.txt"
	printf '%b' "$2" > "$T/settings/flash.txt"
	out=$(bash -c ". '$T/env.sh'; MODE=cli; W='$T/w'; UDIR='$T/unit'; free_bytes() { echo 1000; }; use_backup_setting; backup; echo BACKUP-RETURNED" 2>&1)
	local rc=$? hint=no
	grep -q "With backup=no" <<< "$out" && hint=yes
	if [ $rc != 0 ] && ! grep -q BACKUP-RETURNED <<< "$out" && grep -q "isn't room" <<< "$out" && [ $hint = "$3" ] &&
	   [ ! -e "$T/unit/firmware.bin" ]; then
		ok "$1: stopped$([ $hint = yes ] && echo ", backup=no suggested")"
	else
		bad "$1: exit $rc, hint $hint (want $3)" "$out"
	fi
}
room "too little room for the backups"            'flash=yes\n'           yes
room "too little room even for the firmware's"   'flash=yes\nbackup=no\n' no

# Where the units' folders go: OF-BACKUP if there is one, else this stick's own system.
got=$(bash -c ". '$T/env.sh'; mount_backup() { true; }; choose_backupdir; echo \"\$BACKUPDIR|\$(backups_at u1)\"")
[ "$got" = "$T/of-backup|OF-BACKUP/u1" ] && ok "with OF-BACKUP: the folders there" || bad "with OF-BACKUP: $got"
got=$(bash -c ". '$T/env.sh'; mount_backup() { false; }; choose_backupdir; echo \"\$BACKUPDIR|\$(backups_at u1)|\$(details_at)\"")
if [ "$got" = "$T/state/backups|$T/state/backups/u1, on this stick's system|The details are on this stick's system, in $T/state/backups." ] &&
   [ -d "$T/state/backups" ]; then
	ok "without OF-BACKUP: the folders on this stick's system"
else
	bad "without OF-BACKUP: $got"
fi

# A new unit's info.txt says what was backed up.
rm -rf "$T/of-backup"; mkdir -p "$T/of-backup"
printf 'flash=yes\nbackup=no\n' > "$T/settings/flash.txt"
bash -c ". '$T/env.sh'; BACKUPDIR='$T/of-backup'; CID=c1; use_backup_setting >/dev/null; new_unit" >/dev/null 2>&1
I=$(ls "$T/of-backup"/*/info.txt 2>/dev/null | head -1)
[ -n "$I" ] && grep -q "wasn't backed" "$I" && grep -qx "cid=c1" "$I" && ok "backup=no: the unit's info.txt says the internal memory wasn't backed up" ||
	bad "backup=no: info.txt $(cat "$I" 2>/dev/null | head -4)"

# Stopped at the checks: on a stick in use as a system it says why and starts its system
# (no hold on the login prompt); on a flash stick the message is held, as before.
stop() {    # stop <name> <OF-BACKUP: yes|no> <want: starts|holds>
	rm -rf "$T/run"; : > "$T/tty"
	local D="$T/state/backups"; [ "$2" = yes ] && D="$T/of-backup"
	out=$(bash -c ". '$T/env.sh'; MODE=boot; SCREEN=1; W='$T/w'; BACKUPDIR='$D'; unset UDIR
		fail 'This is an OpenFrame 2: OpenFrame Flash is for the OpenFrame 1.'; echo AFTER-FAIL" 2>&1)
	local rc=$? got
	if grep -q "COUNTDOWN Starting the system from this stick" <<< "$out" && [ ! -e "$T/run/hold" ]; then got=starts
	elif [ -e "$T/run/hold" ] && ! grep -q COUNTDOWN <<< "$out"; then got=holds
	else got="neither"; fi
	if [ "$got" = "$3" ] && [ $rc = 0 ] && ! grep -q AFTER-FAIL <<< "$out" && grep -q "OpenFrame 2" "$T/tty"; then
		ok "$1: $got"
	else
		bad "$1: $got, exit $rc (want $3)" "$out"
	fi
}
stop "stopped at the checks, a stick in use as a system" no  starts
stop "stopped at the checks, a flash stick"              yes holds

# Already installed: a flash stick switches off; a stick in use as a system starts.
already_() {    # already_ <name> <OF-BACKUP: yes|no> <want: starts|poweroff>
	local D="$T/state/backups"; [ "$2" = yes ] && D="$T/of-backup"
	rm -rf "$D"; mkdir -p "$D/20261119-0100-020000000001"
	printf 'cid=c9\nstate=done\n' > "$D/20261119-0100-020000000001/info.txt"
	: > "$T/tty"
	out=$(bash -c ". '$T/env.sh'; MODE=boot; SCREEN=1; W='$T/w'; BACKUPDIR='$D'; CID=c9; already; echo AFTER-ALREADY" 2>&1)
	local got=neither
	grep -q "COUNTDOWN Starting the system from this stick" <<< "$out" && ! grep -q POWEROFF <<< "$out" && got=starts
	grep -q "POWEROFF" <<< "$out" && ! grep -q "COUNTDOWN Starting" <<< "$out" && got=poweroff
	if [ "$got" = "$3" ] && ! grep -q AFTER-ALREADY <<< "$out" && grep -q "Already installed" "$T/tty"; then ok "$1: $got"
	else bad "$1: $got (want $3)" "$out"; fi
}
already_ "already installed, a flash stick"              yes poweroff
already_ "already installed, a stick in use as a system" no  starts

# An OpenFrame 2: its internal memory (twice an OpenFrame 1's) passes the checks, with
# the times for backing it up doubled; one of any other size is refused.
mmc() {    # mmc <name> <bytes> <want: ok|refused> [want MMCSIZE and backup estimate]
	echo x > "$T/bundle"
	out=$(bash -c ". '$T/env.sh'; MODE=cli; W='$T/w'; BUNDLE='$T/bundle'
		internal_mmc() { echo '$T/mmc'; }; blockdev() { echo $2; }; unit_cid() { echo 0123456789abcdef0123456789abcdef; }
		checks; echo \"CHECKED \$MMCSIZE \${PH_EST[mmcbackup]}\"" 2>&1)
	local got=refused
	grep -q "^CHECKED" <<< "$out" && got=ok
	if [ "$got" = "$3" ] && { [ -z "${4:-}" ] || grep -qx "CHECKED $4" <<< "$out"; }; then ok "$1: $got${4:+ ($4)}"
	else bad "$1: $got (want $3${4:+, $4})" "$out"; fi
}
mmc "an OpenFrame 1's internal memory" 1028128768 ok "1028128768 80"
mmc "an OpenFrame 2's internal memory" 2055208960 ok "2055208960 160"
mmc "an internal memory of another size" 4110417920 refused

# The image goes onto an internal memory at least its size: an OpenFrame 2's takes the
# OpenFrame 1-sized image (the write goes on to check the image, which here is a stand-in,
# so stops there); a bigger image is refused.
img() {    # img <name> <MMCSIZE> <image size> <want: written|refused>
	printf 'name=test-image\nsize=%s\nmd5=x\ngzmd5=not-this\n' "$3" > "$T/info"
	rm -rf "$T/unit"; mkdir -p "$T/unit"; echo "state=firmware-ok" > "$T/unit/info.txt"
	out=$(bash -c ". '$T/env.sh'; MODE=cli; W='$T/w'; UDIR='$T/unit'; BUNDLE='$T/bundle'; MMCSIZE=$2; write_mmc" 2>&1)
	local got=other
	grep -q "bigger than this OpenFrame's internal memory" <<< "$out" && got=refused
	grep -q "is damaged" <<< "$out" && got=written
	[ "$got" = "$4" ] && ok "$1: $got" || bad "$1: $got (want $4)" "$out"
}
img "the image onto an OpenFrame 2's internal memory" 2055208960 1028128768 written
img "the image onto an OpenFrame 1's internal memory" 1028128768 1028128768 written
img "an image bigger than the internal memory"         1028128768 2055208960 refused
echo "name=test-image" > "$T/info"

# flash.log in the unit's folder: what was said before the folder was there, then after,
# each line with the time; a second run's lines after the first's.
rm -rf "$T/unit"
out=$(bash -c ". '$T/env.sh'; log 'before the folder'; UDIR='$T/unit'; mkdir -p \$UDIR; log 'in the folder'; log 'and again'" 2>&1)
bash -c ". '$T/env.sh'; UDIR='$T/unit'; log 'a second run'" >/dev/null 2>&1
if [ "$(sed 's/^[0-9-]* [0-9:]* //' "$T/unit/flash.log" 2>/dev/null | tr '\n' '|')" = "before the folder|in the folder|and again|a second run|" ] &&
   grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} before the folder$' "$T/unit/flash.log"; then
	ok "flash.log: the whole run, with the times, and the next run after it"
else bad "flash.log" "$(cat "$T/unit/flash.log" 2>&1)"; fi

# The check after a write reads the internal memory as far as the image goes: on an OpenFrame
# 2's, twice the image, as on an OpenFrame 1's, the same size; a write that didn't take fails.
head -c 4718592 /dev/urandom > "$T/image.raw"   # 4.5 MB: not a whole number of 1M blocks, as the real one isn't
chk() {    # chk <name> <internal memory size> <corrupt: yes|no> <want: written|failed>
	head -c "$2" /dev/zero > "$T/mmc"
	dd if="$T/image.raw" of="$T/mmc" conv=notrunc status=none
	[ "$3" = yes ] && printf 'x' | dd of="$T/mmc" bs=1 seek=3000000 conv=notrunc status=none
	printf 'name=test-image\nsize=%s\nmd5=%s\n' "$(wc -c < "$T/image.raw" | tr -d " ")" "$(md5sum < "$T/image.raw" | cut -d' ' -f1)" > "$T/info"
	rm -rf "$T/unit" "$T/w"; mkdir -p "$T/unit" "$T/w"; echo "state=checking" > "$T/unit/info.txt"
	out=$(bash -c ". '$T/env.sh'; MODE=cli; W='$T/w'; UDIR='$T/unit'; MMCSIZE=$2; check_mmc test && echo CHECKED" 2>&1)
	local got=failed
	grep -q "^CHECKED" <<< "$out" && grep -qx "state=written" "$T/unit/info.txt" && got=written
	# (on failure, what dd said too: with_progress keeps it in its progress file, $W/progress)
	[ "$got" = "$4" ] && ok "$1: $got" || bad "$1: $got (want $4)" "$out
dd said: $(tr '\r' '\n' < "$T/w/progress" 2>/dev/null | grep -v '^$' | tail -5)
$(df -T "$T" 2>/dev/null | tail -1)"
}
chk "checking a write on an OpenFrame 2's internal memory (twice the image)" 9437184 no written
chk "checking a write on an internal memory the image's size"              4718592 no written
chk "a write that didn't take"                                               9437184 yes failed
echo "name=test-image" > "$T/info"

# Stock firmware named by its carrier, OpenFrame 1 and 2 alike, from a made-up manifest
# with this test chip's blocks 5 and 9; our firmware by its marker.
B5=$(dd if="$T/chip.bin" bs=64k skip=5 count=1 status=none | md5sum | cut -d' ' -f1)
B9=$(dd if="$T/chip.bin" bs=64k skip=9 count=1 status=none | md5sum | cut -d' ' -f1)
fwid() {    # fwid <name> <block 5's labels> <block 9's labels> <want>
	printf '5 %s %s\n9 %s %s\n' "$B5" "$2" "$B9" "$3" > "$T/manifest.txt"
	got=$(bash -c ". '$T/env.sh'; FWMANIFEST='$T/manifest.txt'; fw_identify '$T/chip.bin'")
	[ "$got" = "$4" ] && ok "firmware named: $1: $got" || bad "firmware named: $1: $got (want $4)"
}
fwid "stock O2"                  "26.11.32,o2-stock,verizon,telstra" "o2-stock" "O2"
fwid "stock Cisco OpenFrame 2"   "of2-26.11.32,of2-cisco,of2-telio" "of2-cisco" "Cisco"
fwid "stock Telio OpenFrame 2"   "of2-26.11.32,of2-telio" "of2-26.11.32,of2-26.11.32-dev3,of2-telio" "Telio"
fwid "stock OpenPeak OpenFrame 2" "of2-26.11.32,of2-openpeak" "of2-openpeak" "OpenPeak"
fwid "blocks we don't know"      "something-else" "of2-cisco" "not BirdsLikeWires"
cp "$T/chip.bin" "$T/ours.bin"
printf 'BirdsLikeWires OpenFrame EFI 26.11.32 (OF2)' | dd of="$T/ours.bin" bs=1 seek=$((11 * 65536 + 100)) conv=notrunc status=none
got=$(bash -c ". '$T/env.sh'; FWMANIFEST='$T/manifest.txt'; fw_identify '$T/ours.bin'")
[ "$got" = "26.11.32" ] && ok "firmware named: ours on an OpenFrame 2: $got" || bad "firmware named: ours on an OpenFrame 2: $got"

# Settings, and the finish, on a stick in use as a system (no OF-BACKUP) and on a flash
# stick: the system stick gives the unit only its Wi-Fi network (no fixed address) and
# keeps all its own settings; the flash stick gives the unit them all and goes back to
# the blank ones.
mkdir -p "$T/templates"
cp "$HERE/../overlay-debian-trixie/boot/settings/"*.txt "$T/templates/"
sets() {    # sets <system | flash>: run keep_settings then finish, at boot
	rm -rf "$T/settings" "$T/state" "$T/sunit"; mkdir -p "$T/settings" "$T/sunit" "$T/sbk"
	printf 'flash=again\n' > "$T/settings/flash.txt"
	printf '\xef\xbb\xbf## mine\r\naddress=192.168.1.50\r\ngateway=192.168.1.1\r\nName = My Net\r\npassword=pa=ss word\r\n' > "$T/settings/wifi.txt"
	printf 'name=kitchen\n' > "$T/settings/name.txt"
	printf 'project=x\n' > "$T/settings/setup.txt"
	echo "state=written" > "$T/sunit/info.txt"
	bash -c ". '$T/env.sh'; TEMPLATES='$T/templates'; MODE=boot; CID=c1; UDIR='$T/sunit'; W='$T/w'; mkdir -p \$W
		if [ $1 = system ]; then BACKUPDIR='$T/sbk'; else BACKUPDIR=\$BACKUPMNT; mkdir -p \$BACKUPDIR; fi
		keep_settings; cp -r '$T/state/units/c1/settings' '$T/kept'
		finish" > "$T/sets.out" 2>&1
}
sed -i 's#/usr/lib/openframe/bootrw #: #g' "$T/lib.sh"
rm -rf "$T/kept"; sets system
K=$(ls "$T/kept" | tr '\n' ' ')
if [ "$K" = "wifi.txt " ] && grep -qx 'Name = My Net' "$T/kept/wifi.txt" && grep -qx 'password=pa=ss word' "$T/kept/wifi.txt" &&
	grep -qx 'address=' "$T/kept/wifi.txt" && grep -q '^## Wireless network settings' "$T/kept/wifi.txt"; then
	ok "system stick: the unit gets only the Wi-Fi name and password, in the blank wifi.txt"
else bad "system stick: the unit gets $K" "$(cat "$T/kept/wifi.txt" 2>/dev/null; cat "$T/sets.out")"; fi
if grep -q 'address=192.168.1.50' "$T/settings/wifi.txt" && grep -qx 'name=kitchen' "$T/settings/name.txt" &&
	grep -qx 'project=x' "$T/settings/setup.txt" && grep -qx 'flash=yes' "$T/settings/flash.txt"; then
	ok "system stick: keeps its own settings (flash=again becomes yes)"
else bad "system stick: its settings changed" "$(head -50 "$T/settings/"*.txt; cat "$T/sets.out")"; fi
rm -rf "$T/kept"; sets flash
if [ -f "$T/kept/name.txt" ] && [ -f "$T/kept/setup.txt" ] && grep -q '192.168.1.50' "$T/kept/wifi.txt" &&
	grep -qx 'name=' "$T/settings/name.txt" && grep -qx 'address=' "$T/settings/wifi.txt" && grep -qx 'flash=yes' "$T/settings/flash.txt"; then
	ok "flash stick: the unit gets all its settings; the stick goes back to the blank ones"
else bad "flash stick: settings" "$(ls "$T/kept"; head -50 "$T/settings/"*.txt; cat "$T/sets.out")"; fi

[ $FAILS = 0 ] && echo "All passed." || echo "$FAILS failed."
exit $FAILS
