#!/bin/bash
# test_of_audio.sh: of-audio (overlay-debian-trixie/usr/local/sbin/of-audio), where the sound
# goes, with stand-ins for /proc/asound and amixer: the OpenFrame's own card mixed through
# dmix; the images' old asound.conf taken over, someone's own left alone (hotplug too); a
# DAC new to the unit becoming the output at a low volume, the OpenFrame's own while it's
# unplugged, and back to it once it's in again; direct (plug straight to the DAC, its volume
# at full) and back (low again); the OpenFrame's own chosen with the DAC in, and kept; a DAC
# with no volume control getting a software one; a unit whose only card is a DAC; status;
# the OpenFrame 2's DECT base (USB, mono at 16 kHz) not taken for a DAC; set refusing what
# it doesn't know. In a Debian Trixie container (Docker) unless it's root
# in one:
#   bash tests/test_of_audio.sh
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
if [ "$(id -u)" -ne 0 ] || [ ! -e /.dockerenv ]; then
	exec docker run --rm -v "$HERE:/src:ro" debian:trixie bash /src/tests/test_of_audio.sh
fi
FAILS=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; [ -n "${2:-}" ] && sed 's/^/       /' <<< "$2" | tail -14; FAILS=$((FAILS + 1)); }

A=/src/overlay-debian-trixie/usr/local/sbin/of-audio
export OF_AUDIO_PROC=/tmp/proc OF_AUDIO_ASOUND=/tmp/asound.conf OF_AUDIO_STATE=/tmp/state OF_AUDIO_NOBOOTRW=1 OF_AUDIO_SETTLE=0
mkdir -p /boot/settings /usr/lib/openframe/settings /tmp/proc /tmp/mix /stub
cp /src/overlay-debian-trixie/boot/settings/audio.txt /usr/lib/openframe/settings/
cp /src/overlay-debian-trixie/boot/settings/audio.txt /boot/settings/
T=/boot/settings/audio.txt

# amixer: each card's controls are files in /tmp/mix/<card>/ holding their level ("none" for
# a switch with no volume)
cat > /stub/alsactl <<'EOF'
#!/bin/bash
echo "alsactl $*" >> /tmp/alsactl.calls
EOF
chmod 755 /stub/alsactl
cat > /stub/amixer <<'EOF'
#!/bin/bash
[ "$1" = -q ] && shift
[ "$1" = -M ] && shift
card=$2 cmd=$3 name=${4:-}
d=/tmp/mix/$card
case "$cmd" in
	scontrols) for f in "$d"/*; do [ -e "$f" ] && echo "Simple mixer control '${f##*/}',0"; done ;;
	sget) [ -e "$d/$name" ] || exit 1; echo "Simple mixer control '$name',0"
	      if [ "$(cat "$d/$name")" = none ]; then echo "  Capabilities: pswitch"; else echo "  Capabilities: pvolume pswitch"; fi ;;
	sset) [ -e "$d/$name" ] && echo "${5%\%}" > "$d/$name" ;;
esac
EOF
chmod 755 /stub/amixer
# aplay: playing through a softvol default makes its control (at full, as ALSA does)
cat > /stub/aplay <<'EOF'
#!/bin/bash
cat > /dev/null
card=$(sed -n '/type softvol/,/}/{s/.*card "\(.*\)".*/\1/p}' /tmp/asound.conf | head -1)
[ -n "$card" ] && [ ! -e "/tmp/mix/$card/OpenFrame" ] && echo 100 > "/tmp/mix/$card/OpenFrame"
exit 0
EOF
chmod 755 /stub/aplay
# systemctl: what's restarted
printf '#!/bin/sh\necho "systemctl $*" >> /tmp/restarts\n' > /stub/systemctl; chmod 755 /stub/systemctl
# processes playing: a service, a Sprite app, Sprite, and one in a login
export OF_AUDIO_PROCFS=/tmp/procfs
player() {    # player <pid> <cgroup>
	mkdir -p /tmp/procfs/$1/fd; ln -sf /dev/snd/pcmC0D0p /tmp/procfs/$1/fd/5; ln -sf /dev/null /tmp/procfs/$1/fd/0
	echo "0::$2" > /tmp/procfs/$1/cgroup
}
export PATH="/stub:$PATH"

builtin() { printf ' 0 [MID            ]: HDA-Intel - HDA Intel MID\n                      HDA Intel MID at 0xd01c0000 irq 16\n'; }
dac() { printf ' %s [DAC            ]: USB-Audio - USB Audio DAC\n                      Burr-Brown from TI USB Audio DAC at usb-0000:00:1d.1-2, full speed\n' "$1"; }
cards() { : > /tmp/proc/cards; rm -rf /tmp/proc/card*/; for c in "$@"; do case $c in
	mid) builtin >> /tmp/proc/cards; mkdir -p /tmp/proc/card0 ;;
	dac*) n=${c#dac}; dac "$n" >> /tmp/proc/cards; mkdir -p /tmp/proc/card$n; echo 08bb:2704 > /tmp/proc/card$n/usbid
	      printf 'Burr-Brown from TI USB Audio DAC at usb-0000:00:1d.1-2, full speed : USB Audio\n\nPlayback:\n  Status: Stop\n  Interface 1\n    Altset 1\n    Format: S16_LE\n    Channels: 2\n    Endpoint: 0x02 (2 OUT) (ADAPTIVE)\n    Rates: 32000, 44100, 48000\n' > /tmp/proc/card$n/stream0 ;;
	other*) n=${c#other}; printf ' %s [Audio          ]: USB-Audio - USB Audio Device\n                      C-Media Electronics Inc. USB Audio Device at usb-0000:00:1d.1-3, full speed\n' "$n" >> /tmp/proc/cards
	      mkdir -p /tmp/proc/card$n; echo 0d8c:0014 > /tmp/proc/card$n/usbid
	      printf 'C-Media USB Audio Device : USB Audio\n\nPlayback:\n  Interface 1\n    Altset 1\n    Format: S16_LE\n    Channels: 2\n    Rates: 44100, 48000\n' > /tmp/proc/card$n/stream0 ;;
	vega*) n=${c#vega}; printf ' %s [USB            ]: USB-Audio - VegaOne USB\n                      Philips VegaOne USB at usb-0000:00:1d.1-1, full speed\n' "$n" >> /tmp/proc/cards
	      mkdir -p /tmp/proc/card$n; echo 04cc:5556 > /tmp/proc/card$n/usbid
	      printf 'Philips VegaOne USB : USB Audio\n\nPlayback:\n  Interface 1\n    Altset 1\n    Format: S16_LE\n    Channels: 1\n    Rates: 16000\n\nCapture:\n  Interface 2\n    Channels: 1\n    Rates: 16000\n' > /tmp/proc/card$n/stream0 ;;
	esac; done; }
mkdir -p /tmp/mix/MID /tmp/mix/DAC
echo 50 > /tmp/mix/MID/Master; echo none > /tmp/mix/MID/IEC958
echo 90 > /tmp/mix/DAC/PCM
pcm() { grep -o 'hw:CARD=[A-Za-z0-9_]*' /tmp/asound.conf | head -1; }
setting() { sed -n "s/^$1=//p" $T; }

# The images' old asound.conf, taken over.
cat > /tmp/asound.conf <<'EOF'
pcm.mixer {
  type dmix
  ipc_key 3141
  ipc_key_add_uid false
  ipc_perm 0666
  slave {
    channels 2
    pcm {
      type hw
      card 0
    }
  }
  bindings {
    0 0
    1 1
  }
}

pcm.!default {
  type plug
  slave.pcm "mixer"
}

ctl.!default {
  type hw
  card 0
}
EOF
cards mid
out=$(bash $A apply 2>&1)
[ "$(pcm)" = hw:CARD=MID ] && grep -q 'type dmix' /tmp/asound.conf && grep -q '^ctl.!default' /tmp/asound.conf && head -1 /tmp/asound.conf | grep -q '^# Written by of-audio' &&
	ok "the OpenFrame's own, mixed; the old asound.conf taken over" || bad "the OpenFrame's own, mixed" "$out
$(cat /tmp/asound.conf)"
st=$(bash $A status)
grep -qx 'card=MID builtin - HDA Intel MID' <<< "$st" && grep -qx output=MID <<< "$st" && grep -qx mixer=Master <<< "$st" && grep -qx direct=no <<< "$st" &&
	ok "status: the card, the output, its volume control" || bad "status" "$st"

# Someone's own asound.conf: left alone, by hotplug too.
printf 'pcm.!default { type hw card 1 }\n' > /tmp/asound.conf
cards mid dac1
out=$(bash $A hotplug 2>&1)
[ "$(cat /tmp/asound.conf)" = 'pcm.!default { type hw card 1 }' ] && [ "$(setting output)" = builtin ] && [ "$(cat /tmp/mix/DAC/PCM)" = 90 ] &&
	bash $A status | grep -qx managed=no && ok "someone's own asound.conf: left alone, DAC and all" || bad "someone's own asound.conf" "$out"
rm /tmp/asound.conf

# A DAC new to the unit: the output, low.
cards mid
bash $A hotplug 2>/dev/null
cards mid dac1
out=$(bash $A hotplug 2>&1)
[ "$(setting output)" = 08bb:2704 ] && [ -z "$(setting direct)" ] && [ "$(pcm)" = hw:CARD=DAC ] && grep -q 'ipc_key 3142' /tmp/asound.conf &&
	[ "$(cat /tmp/mix/DAC/PCM)" = 25 ] && ok "a new DAC: the output, mixed, at 25%" || bad "a new DAC" "$out
$(cat $T | grep -v '^#')
$(cat /tmp/asound.conf)"
echo 60 > /tmp/mix/DAC/PCM

# Unplugged: the OpenFrame's own; back in: the DAC again, its volume as it was.
cards mid
bash $A hotplug 2>/dev/null
[ "$(pcm)" = hw:CARD=MID ] && [ "$(setting output)" = 08bb:2704 ] && ok "unplugged: the OpenFrame's own, the DAC still chosen" || bad "unplugged" "$(cat /tmp/asound.conf)"
cards mid dac1
bash $A hotplug 2>/dev/null; rc=$?
[ "$(pcm)" = hw:CARD=DAC ] && [ "$(cat /tmp/mix/DAC/PCM)" = 60 ] && ok "back in: the DAC, its volume as it was" || bad "back in" "$(cat /tmp/mix/DAC/PCM)"
# Nothing new (as at most starts): still a success, or systemd shows the service as failed
[ $rc -eq 0 ] && ok "hotplug with no new DAC: exit 0" || bad "hotplug with no new DAC: exit $rc"

# openframe-resampler's converter: plug uses it where it's installed (not the linear one),
# and the mixer's periods are 4410 frames at 44.1 kHz (147 x 30: 48 kHz meets it at 160/147).
grep -q 'period_size 4410' /tmp/asound.conf && grep -q 'buffer_size 17640' /tmp/asound.conf && ! grep -q rate_converter /tmp/asound.conf &&
	ok "the mixer's periods 4410 frames; no converter named without openframe-resampler" || bad "periods, no converter" "$(cat /tmp/asound.conf)"
touch /tmp/rate_openframe.so
OF_AUDIO_RATEMOD=/tmp/rate_openframe.so bash $A apply 2>/dev/null
[ "$(grep -c 'rate_converter "openframe"' /tmp/asound.conf)" = 1 ] && ok "with openframe-resampler: plug uses its converter" || bad "the converter" "$(cat /tmp/asound.conf)"
OF_AUDIO_RATEMOD=/tmp/rate_openframe.so bash $A set direct=yes 2>/dev/null
grep -q 'rate_converter "openframe"' /tmp/asound.conf && grep -q 'slave.pcm "hw:CARD=DAC"' /tmp/asound.conf && ! grep -q period_size /tmp/asound.conf &&
	ok "direct: the converter too (for a rate the DAC can't take), no mixer periods" || bad "direct, the converter" "$(cat /tmp/asound.conf)"
OF_AUDIO_RATEMOD=/tmp/rate_openframe.so bash $A set direct=no 2>/dev/null
rm /tmp/rate_openframe.so
bash $A apply 2>/dev/null
echo 60 > /tmp/mix/DAC/PCM

# Mixed, the DAC runs in its fullest format at 44.1 kHz when it takes it (so 44.1 kHz music
# isn't resampled, and a change of mode is less often a change of what it's sent).
grep -q 'rate 44100' /tmp/asound.conf && grep -q 'format S16_LE' /tmp/asound.conf &&
	ok "mixed: the DAC at 44.1 kHz in its fullest format" || bad "mixed: the DAC's rate and format" "$(cat /tmp/asound.conf)"

# Direct: straight to it, its volume at full; and back, low.
out=$(bash $A set direct=yes 2>&1)
grep -q 'slave.pcm "hw:CARD=DAC"' /tmp/asound.conf && ! grep -q 'format ' /tmp/asound.conf && ! grep -q 'rate ' /tmp/asound.conf &&
	! grep -q dmix /tmp/asound.conf && [ "$(cat /tmp/mix/DAC/PCM)" = 100 ] &&
	bash $A status | grep -qx mixer= && bash $A status | grep -qx direct=yes && ok "direct: plug straight to the DAC, its volume at full" || bad "direct" "$out
$(cat /tmp/asound.conf)"
bash $A set direct=no 2>/dev/null
grep -q dmix /tmp/asound.conf && [ "$(cat /tmp/mix/DAC/PCM)" = 25 ] && ok "volume control again: mixed, low" || bad "volume control again" "$(cat /tmp/mix/DAC/PCM)"

# Direct, and the DAC's level put back by ALSA as it comes in again (a replug, a power cut):
# the next hotplug has it at full again, with no slider there to raise it.
bash $A set direct=yes 2>/dev/null
echo 30 > /tmp/mix/DAC/PCM
bash $A hotplug 2>/dev/null
[ "$(cat /tmp/mix/DAC/PCM)" = 100 ] && grep -q 'slave.pcm "hw:CARD=DAC"' /tmp/asound.conf &&
	ok "direct after a replug: the DAC's volume at full again" || bad "direct after a replug" "$(cat /tmp/mix/DAC/PCM)"
bash $A set direct=no 2>/dev/null

# The mixer at 48 kHz (mixer_rate=48000), the DAC taking it: 4800-frame periods, the same time.
# Back to 44.1 kHz. And on the OpenFrame's own card too.
bash $A set mixer_rate=48000 2>/dev/null
[ "$(setting mixer_rate)" = 48000 ] && grep -q 'rate 48000' /tmp/asound.conf && grep -q 'period_size 4800' /tmp/asound.conf &&
	bash $A status | grep -qx mixer_rate=48000 && ok "mixer_rate=48000: the DAC mixed at 48 kHz, 4800-frame periods" ||
	bad "mixer_rate=48000" "$(setting mixer_rate); $(cat /tmp/asound.conf)"
bash $A set output=builtin 2>/dev/null
grep -q 'hw:CARD=MID' /tmp/asound.conf && grep -q 'rate 48000' /tmp/asound.conf && ok "and the OpenFrame's own at 48 kHz" || bad "the OpenFrame's own at 48 kHz" "$(cat /tmp/asound.conf)"
bash $A set output=08bb:2704 mixer_rate=44100 2>/dev/null
grep -q 'rate 44100' /tmp/asound.conf && grep -q 'period_size 4410' /tmp/asound.conf && bash $A status | grep -qx mixer_rate=44100 &&
	ok "mixer_rate=44100: back to 44.1 kHz" || bad "back to 44.1 kHz" "$(cat /tmp/asound.conf)"
bash $A set mixer_rate=96000 >/dev/null 2>&1 && bad "mixer_rate other than 44100 or 48000 refused" || ok "mixer_rate other than 44100 or 48000 refused"
echo 60 > /tmp/mix/DAC/PCM

# Direct is each DAC's own: one going direct doesn't make another, chosen after it, go
# direct at full volume; going back to the first, it's direct again.
mkdir -p /tmp/mix/Audio; echo 40 > /tmp/mix/Audio/PCM
cards mid dac1 other2
bash $A set output=08bb:2704 direct=yes 2>/dev/null
bash $A set output=0d8c:0014 2>/dev/null
[ "$(setting direct)" = 08bb:2704 ] && [ "$(pcm)" = hw:CARD=Audio ] && grep -q dmix /tmp/asound.conf && [ "$(cat /tmp/mix/Audio/PCM)" = 40 ] &&
	bash $A status | grep -qx direct=no && ok "direct for one DAC: another chosen after it is mixed, its volume as it was" ||
	bad "direct for one DAC, another chosen" "$(setting direct); $(cat /tmp/mix/Audio/PCM)
$(cat /tmp/asound.conf)"
bash $A set output=08bb:2704 2>/dev/null
grep -q 'slave.pcm "hw:CARD=DAC"' /tmp/asound.conf && [ "$(cat /tmp/mix/DAC/PCM)" = 100 ] &&
	ok "and back to the first: direct again, at full" || bad "back to the direct DAC" "$(cat /tmp/asound.conf)"
bash $A set output=0d8c:0014 direct=yes 2>/dev/null
[ "$(setting direct)" = "08bb:2704 0d8c:0014" ] && ok "both direct: direct=08bb:2704 0d8c:0014" || bad "both direct" "$(setting direct)"
bash $A set direct=no 2>/dev/null
[ "$(setting direct)" = 08bb:2704 ] && grep -q dmix /tmp/asound.conf && ok "direct=no for the output's DAC alone" || bad "direct=no for one" "$(setting direct)"
# audio.txt from before, direct=yes: the output's DAC's, and written so as another's chosen.
sed -i 's/^direct=.*/direct=yes/; s/^output=.*/output=08bb:2704/' $T
bash $A apply 2>/dev/null
grep -q 'slave.pcm "hw:CARD=DAC"' /tmp/asound.conf && ok "direct=yes from before: the output's DAC goes direct" || bad "direct=yes from before" "$(cat /tmp/asound.conf)"
bash $A set output=0d8c:0014 2>/dev/null
[ "$(setting direct)" = 08bb:2704 ] && grep -q dmix /tmp/asound.conf && ok "and is written as that DAC's as another is chosen" || bad "direct=yes from before, another chosen" "$(setting direct)"
# A new DAC plugged in: not direct, whatever the others are.
rm -f /tmp/state/seen; echo 08bb:2704 > /tmp/state/seen
cards mid dac1
bash $A hotplug 2>/dev/null
cards mid dac1 other2
bash $A hotplug 2>/dev/null
[ "$(setting output)" = 0d8c:0014 ] && [ "$(setting direct)" = 08bb:2704 ] && grep -q dmix /tmp/asound.conf &&
	ok "a new DAC: the output, mixed; the other DAC still direct" || bad "a new DAC beside a direct one" "$(setting output) $(setting direct)"
bash $A set output=08bb:2704 2>/dev/null; bash $A set direct=no 2>/dev/null
cards mid dac1
bash $A set output=builtin direct=yes >/dev/null 2>&1 && bad "direct for the OpenFrame's own refused" || ok "direct for the OpenFrame's own refused"

# The OpenFrame's own chosen with the DAC in: kept, through a hotplug.
bash $A set output=builtin 2>/dev/null
bash $A hotplug 2>/dev/null
[ "$(pcm)" = hw:CARD=MID ] && [ "$(setting output)" = builtin ] && ok "the OpenFrame's own chosen with the DAC in: it stays" || bad "builtin chosen" "$(setting output)"
grep -q "^## Audio" $T && grep -q "^# The DACs that get the audio direct" $T && ok "audio.txt keeps its notes" || bad "audio.txt keeps its notes" "$(cat $T)"

# A DAC with no volume control: a software one.
rm /tmp/mix/DAC/PCM; echo none > /tmp/mix/DAC/Switch
bash $A set output=08bb:2704 2>/dev/null
grep -q 'type softvol' /tmp/asound.conf && grep -q 'name "OpenFrame"' /tmp/asound.conf && bash $A status | grep -qx mixer=OpenFrame &&
	ok "a DAC with no volume control: a software one" || bad "no volume control" "$(cat /tmp/asound.conf)"
[ "$(cat /tmp/mix/DAC/OpenFrame 2>/dev/null)" = 25 ] && ok "made straight away (not at full when something first plays), at 25%" ||
	bad "the software control made at once, low" "$(ls /tmp/mix/DAC; cat /tmp/mix/DAC/OpenFrame 2>&1)"
rm -f /tmp/mix/DAC/OpenFrame /tmp/mix/DAC/Switch
echo 40 > /tmp/mix/DAC/PCM

# A unit whose only card is a DAC (the OpenFrame's own turned off): that, whatever's asked.
bash $A set output=builtin 2>/dev/null
cards dac0
bash $A apply 2>/dev/null
[ "$(pcm)" = hw:CARD=DAC ] && grep -q 'ipc_key 3141' /tmp/asound.conf && ok "only a DAC: that" || bad "only a DAC" "$(cat /tmp/asound.conf)"

# The OpenFrame 2's own DECT base (mono, 16 kHz): not an output, nor a new DAC to switch to.
rm -f /tmp/state/seen
bash $A set output=builtin 2>/dev/null
cards mid vega1
out=$(bash $A hotplug 2>&1)
[ "$(pcm)" = hw:CARD=MID ] && [ "$(setting output)" = builtin ] && ! bash $A status | grep -q '^card=USB' &&
	ok "the OF2's DECT base (mono, 16 kHz): not a DAC" || bad "the OF2's DECT base" "$out
$(bash $A status)"
cards mid vega1 dac2
bash $A hotplug 2>/dev/null
[ "$(setting output)" = 08bb:2704 ] && ok "and a real DAC beside it still is" || bad "a DAC beside the DECT base" "$(setting output)"

# Something playing when the output changes: services start again (playing the new way);
# Sprite's apps are listed for Sprite; Sprite itself and a program run in a login are left.
rm -rf /tmp/procfs /tmp/restarts
player 101 /system.slice/shairport-sync.service
player 102 /system.slice/sprite-app-radio.service
player 103 /system.slice/sprite.service
player 104 /user.slice/user-1000.slice/session-3.scope
mkdir -p /tmp/procfs/105/fd; ln -sf /dev/snd/controlC0 /tmp/procfs/105/fd/4; echo "0::/system.slice/other.service" > /tmp/procfs/105/cgroup
cards mid dac1
bash $A set output=08bb:2704 2>/dev/null
[ "$(cat /tmp/restarts 2>/dev/null)" = "systemctl --no-block restart shairport-sync.service" ] &&
	ok "the output changed: a service playing is restarted, and only that" || bad "what's restarted" "$(cat /tmp/restarts 2>&1)"
st=$(bash $A status)
grep -qx holder=sprite-app-radio.service <<< "$st" && grep -qx holder=- <<< "$st" && ! grep -q holder=other <<< "$st" &&
	ok "status lists what's playing (for Sprite's apps)" || bad "status lists what's playing" "$st"
rm -f /tmp/restarts
bash $A apply 2>/dev/null
[ ! -e /tmp/restarts ] && ok "nothing changed: nothing restarted" || bad "nothing changed: nothing restarted" "$(cat /tmp/restarts)"
rm -rf /tmp/procfs

# The DAC unplugged while it plays: its device node is gone, so the player's link to it
# reads "... (deleted)". It's still found, and restarted to play from the speaker.
rm -rf /tmp/procfs /tmp/restarts
mkdir -p /tmp/procfs/106/fd; ln -sf "/dev/snd/pcmC2D0p (deleted)" /tmp/procfs/106/fd/5
echo "0::/system.slice/shairport-sync.service" > /tmp/procfs/106/cgroup
cards mid
bash $A set output=builtin 2>/dev/null
[ "$(cat /tmp/restarts 2>/dev/null)" = "systemctl --no-block restart shairport-sync.service" ] &&
	ok "a DAC unplugged while playing: the player is still found and restarted" || bad "a player of an unplugged DAC" "$(cat /tmp/restarts 2>&1)"
rm -rf /tmp/procfs /tmp/restarts

# What set doesn't know.
cp $T /tmp/before
bash $A set output=hdmi >/dev/null 2>&1 && bad "set refuses an output it doesn't know" || ok "set refuses an output it doesn't know"
bash $A set direct=maybe >/dev/null 2>&1 && bad "and a direct that isn't yes or no" || ok "and a direct that isn't yes or no"
cmp -s $T /tmp/before && ok "changing nothing" || bad "changing nothing"

echo
[ "$FAILS" -eq 0 ] && echo "all passed" || echo "$FAILS failed"
exit "$FAILS"
