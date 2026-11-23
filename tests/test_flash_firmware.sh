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
# A write that takes a while, for a stop signal to land in (as the real one's last ~30 s),
# with stop signals ignored, as the real one does from its first write.
trap '' HUP INT TERM
[ -n "${STANDIN_SLEEP:-}" ] && sleep "$STANDIN_SLEEP"
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
case_ "never verifies: stops after ten tries"        2         stop

# Ten tries that didn't verify: the unit's state says so, the panel says the chip may be
# failing and where to look, and the next start with the stick in stops there again.
if grep -q "^state=firmware-failed" "$T/unit/info.txt" && grep -q "openframe-failure" "$T/tty" &&
   grep -q "may be failing" "$T/tty" && [ "$(cat "$T/runs")" = 10 ]; then
	echo "ok   ten tries: state firmware-failed, the failure screen"
else
	echo "FAIL ten tries: $(cat "$T/runs") tries, $(grep '^state=' "$T/unit/info.txt")"; FAILS=$((FAILS + 1))
fi
grep -q '^		firmware-failed) fw_failed ;;$' "$SRC" && echo "ok   a restart in firmware-failed stops again, no tries" ||
	{ echo "FAIL firmware-failed isn't a state the flash stops at"; FAILS=$((FAILS + 1)); }

# Many tries that don't verify: only the newest dump folders stay (the one kept before the
# last try, and the last try's own).
rm -rf "$T/dumps" "$T/runs" "$T/unit"; mkdir -p "$T/dumps" "$T/unit"; echo "state=backed-up" > "$T/unit/info.txt"
printf '2\n%.0s' $(seq 9) > "$T/seq"; echo 0 >> "$T/seq"
timeout 120 bash "$T/run.sh" "$T" > /dev/null 2>&1
N=$(ls -1d "$T/dumps/of-firmware-update."* 2>/dev/null | wc -l)
if [ "$N" -le 2 ]; then echo "ok   9 tries that didn't verify, then updated: $N dump folders left"
else echo "FAIL 9 tries that didn't verify, then updated: $N dump folders left (want 2 at most)"; FAILS=$((FAILS + 1)); fi

# A shutdown (or Ctrl-C, or a dropped session) part way through the update: the flash
# carries on until the firmware is written and checked, then stops, rather than going on
# to the internal memory (the next start carries on from there).
rm -rf "$T/dumps" "$T/runs" "$T/unit" "$T/run"; mkdir -p "$T/dumps" "$T/unit"; echo "state=backed-up" > "$T/unit/info.txt"
echo 0 > "$T/seq"
STANDIN_SLEEP=1.5 timeout 60 bash "$T/run.sh" "$T" > "$T/stop.out" 2>&1 &
P=$!
for i in $(seq 50); do [ -s "$T/runs" ] && break; sleep 0.1; done
sleep 0.3
for SIG in TERM INT HUP; do kill -s $SIG $P 2>/dev/null; pkill --signal $SIG -f "$T/upd" 2>/dev/null; done
wait $P
if grep -q "stopping now it's written" "$T/stop.out" && ! grep -q "CARRIED ON" "$T/stop.out" &&
   grep -q "^state=firmware-ok" "$T/unit/info.txt"; then
	echo "ok   stop signals part way through: firmware finished, then stopped"
else
	echo "FAIL stop signals part way through: $(grep -c . "$T/stop.out") lines of output, state $(sed -n 's/^state=//p' "$T/unit/info.txt")"
	sed 's/^/       /' "$T/stop.out" | tail -8
	FAILS=$((FAILS + 1))
fi

[ $FAILS = 0 ] && echo "All passed." || echo "$FAILS failed."
exit $FAILS
