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
bad() { echo "FAIL $1"; [ -n "${2:-}" ] && sed 's/^/       /' <<< "$2" | tail -10; FAILS=$((FAILS + 1)); }

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

[ $FAILS = 0 ] && echo "All passed." || echo "$FAILS failed."
exit $FAILS
