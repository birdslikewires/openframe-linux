#!/bin/bash
# test_flash_firmware.sh: OpenFrame Flash's firmware step (fw_update in
# overlay-debian-trixie/usr/lib/openframe/flash/flash), at boot, against a stand-in for
# of-firmware-update that exits as each case says, try by try: what the flash does after
# each (carry on to the internal memory, restart, or stop), that it never carries on or
# stops once a try hasn't verified, whatever a later try says, and that it keeps only the
# newest of the updater's dump folders. Nothing real is touched: the flash's functions are
# loaded without its main part, with its paths in a directory of its own, the panel a
# file, and the restart and sounds stood in for. Run on Linux (it reads /proc/uptime), as
# any user:
#   bash tests/test_flash_firmware.sh [path to flash]
# Prints one line per case; exits non-zero if any case fails.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${1:-$HERE/../overlay-debian-trixie/usr/lib/openframe/flash/flash}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
FAILS=0

# The stand-in updater: the next exit code from $T/seq (2 once they run out, as a write
# that won't verify would), with a dump folder made as the real one makes it, and the
# lines the screen reads.
cat > "$T/upd" <<'EOF'
#!/bin/bash
T=$(dirname "$0")
say() { echo "of-firmware-update: $*"; }
say "firmware now: blocks that differ from 26.11.30: 5:o2-stock+ 6:o2-stock+ 7:o2-stock 8:o2-stock 9:o2-stock 10:blank"
say "plan: write blocks 10 5 6 7 8 9"
N=$(( $(cat "$T/runs" 2>/dev/null || echo 0) + 1 )); echo $N > "$T/runs"
RC=$(sed -n "${N}p" "$T/seq"); RC=${RC:-2}
D=$(mktemp -d "$T/dumps/of-firmware-update.XXXXXX"); head -c 1024 /dev/zero > "$D/pre1.bin"
case $RC in
	0) for n in 10 5 6 7 8 9; do say "block $n written and verified"; done
	   say "UPDATED: the firmware is 26.11.30, verified (read-back x); dumps in $D" ;;
	1) rm -rf "$D"; say "STOP: could not make a work directory. Nothing was written; the chip is as it was." ;;
	2) say "block 10 written and verified"; say "FAILED: block 5 does not verify after 3 tries. DO NOT REBOOT OR POWER OFF: the unit may not start." ;;
	3) rm -rf "$D"; say "this firmware is not one we know (block 7 matches no release or stock firmware we have), so it is left alone. Nothing was written." ;;
	4) rm -rf "$D"; say "flash blocks 10 are locked down until the next reset: reboot, then run this again" ;;
esac
exit $RC
EOF
chmod +x "$T/upd"

# The flash without its main part (from its root check on).
sed '/^if \[ "\$(id -u)" -ne 0 \]; then$/,$d' "$SRC" > "$T/lib.sh"
grep -q '^fw_update() {' "$T/lib.sh" || { echo "FAIL: no fw_update in $SRC"; exit 1; }

# One run of the firmware step at boot, as a stock O2 unit that's been backed up, in a
# shell of its own (the flash exits when it stops or restarts): "CARRIED ON" if the step
# returned, for the internal memory's write.
cat > "$T/run.sh" <<'EOF'
#!/bin/bash
T=$1
. "$T/lib.sh"
MODE=boot; SCREEN=1; P_DRAWN=""; TTY="$T/tty"
W="$T/w"; mkdir -p "$W"; UDIR="$T/unit"; BUNDLEINFO="$T/info"; echo name=test-image > "$BUNDLEINFO"
RUNDIR="$T/run"; HOLD="$RUNDIR/hold"; FWUPDATE="$T/upd"; FW_DUMPS="$T/dumps/of-firmware-update."
OF_FLASH_TEST_NOPOWEROFF=1
sound() { :; }; cleanup() { :; }; console_hush() { :; }; plymouth() { false; }
sleep() { command sleep 0.02; }
fw_update "of-firmware-update: firmware now: blocks that differ from 26.11.30: 5:o2-stock+ 6:o2-stock+ 7:o2-stock 8:o2-stock 9:o2-stock 10:blank
of-firmware-update: plan: write blocks 10 5 6 7 8 9"
echo "CARRIED ON"
EOF

# case <name> <exit codes, try by try> <want: carry-on | restart | stop> [firmware_locked set before: yes]
case_() {
	local name=$1 seq=$2 want=$3 lock=${4:-} out got runs
	rm -rf "$T/dumps" "$T/runs" "$T/unit" "$T/run"; mkdir -p "$T/dumps" "$T/unit"; : > "$T/tty"
	echo "state=backed-up" > "$T/unit/info.txt"
	[ "$lock" = yes ] && echo "firmware_locked=earlier" >> "$T/unit/info.txt"
	tr ',' '\n' <<< "$seq" > "$T/seq"
	out=$(timeout 60 bash "$T/run.sh" "$T" 2>&1)
	runs=$(cat "$T/runs" 2>/dev/null || echo 0)
	if grep -q "CARRIED ON" <<< "$out"; then got=carry-on
	elif grep -q "would restart now" <<< "$out"; then got=restart
	elif grep -q "^stopped=" "$T/unit/info.txt"; then got=stop
	else got="nothing (timed out?)"; fi
	if [ "$got" = "$want" ]; then
		echo "ok   $name: $got after $runs tr$([ "$runs" = 1 ] && echo y || echo ies)"
	else
		echo "FAIL $name: $got after $runs tries (want $want)"
		sed 's/^/       /' <<< "$out" | grep -v ': block [0-9]* written' | tail -12
		FAILS=$((FAILS + 1))
	fi
}

case_ "updated"                                     0         carry-on
case_ "refused, nothing written"                    1         stop
case_ "not recognised"                              3         stop
case_ "locked: restart once"                        4         restart
case_ "still locked after the restart"              4         stop yes
case_ "didn't verify, then updated"                 2,0       carry-on
case_ "didn't verify, then 'nothing written' (1)"   2,1,0     carry-on
case_ "didn't verify, then not recognised (3)"      2,3,0     carry-on
case_ "didn't verify, then locked (4)"              2,4,0     carry-on
case_ "didn't verify, then 1, 3 and 4, then updated" 2,1,3,4,0 carry-on

# Many tries that don't verify: only the newest dump folders stay (the one kept before the
# last try, and the last try's own).
rm -rf "$T/dumps" "$T/runs" "$T/unit"; mkdir -p "$T/dumps" "$T/unit"; echo "state=backed-up" > "$T/unit/info.txt"
printf '2\n%.0s' $(seq 12) > "$T/seq"; echo 0 >> "$T/seq"
timeout 120 bash "$T/run.sh" "$T" > /dev/null 2>&1
N=$(ls -1d "$T/dumps/of-firmware-update."* 2>/dev/null | wc -l)
if [ "$N" -le 2 ]; then echo "ok   12 tries that didn't verify, then updated: $N dump folders left"
else echo "FAIL 12 tries that didn't verify, then updated: $N dump folders left (want 2 at most)"; FAILS=$((FAILS + 1)); fi

[ $FAILS = 0 ] && echo "All passed." || echo "$FAILS failed."
exit $FAILS
