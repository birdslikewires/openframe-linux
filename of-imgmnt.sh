#!/usr/bin/env bash

# ofimgmnt.sh v1.05 (18th July 2019)
#  For mounting an image file.

#set -x

RND=$RANDOM

# Which loops to use.
LOOP=`losetup -f | awk -F\loop {'print $2'}`
[ $LOOP -lt 4 ] && LOOP=4
LOOPINITIAL=$LOOP

## Checks

if [ "$#" -ne 1 ]; then
  echo "$0 <image>"
  exit 1
fi

if [ "$USER" != "root" ]; then
  echo "You need to run this with superuser privileges."
  exit 1
fi

IMG="$1"

if [[ "$IMG" =~ ".img.gz" ]]; then
  echo "Cannot be a compressed image file."
  exit 1
fi

PARTINFO=`parted -m "$IMG" unit b print`
PARTCHECK=`echo "$PARTINFO" | wc -l`

#[ $PARTCHECK -ne 4 ] && echo "Unexpected number of partitions. We can only handle two!" && exit 1

PARTCOUNTER="0"
while read -r pl; do

	if [[ "$pl" =~ ^[0-9] ]]; then

		PARTLIST="${PARTLIST}${pl}"$'\n'
		PARTCOUNTER=$((PARTCOUNTER+1))

	fi

done <<< "$PARTINFO"

echo "Found $PARTCOUNTER partitions inside $IMG..."
echo

cleanup() {
	trap '' INT
	MYLOOP=$1
	MYREPS=$2
	echo
	echo -n "Unmounting $MYREPS partitions..."
	sync
	sync
	for i in {1..6}; do
		umount -f /tmp/image-$RND/* 2>/dev/null
	done
	echo " done."
	echo

	MYLOOPCOUNTER=0
	while [[ $MYREPS -gt $MYLOOPCOUNTER ]]; do

		echo "Disconnecting /dev/loop$MYLOOP"

		losetup -d /dev/loop$MYLOOP

		MYLOOP=$((MYLOOP+1))
		MYLOOPCOUNTER=$((MYLOOPCOUNTER+1))

	done

	rm -rf /tmp/image-$RND

	echo
	echo "Finished."
	exit
}

LOOPPARTCOUNTER="1"
while read -r pl; do

	if [[ "$pl" =~ ^[0-9] ]]; then

		POFF=`echo "$pl" | cut -d: -f 2 | sed -e "s/\([0-9]\+\)B/\1/g"`
		PSZE=`echo "$pl" | cut -d: -f 4 | sed -e "s/\([0-9]\+\)B/\1/g"`
		PTYP=`echo "$pl" | cut -d: -f 5 | sed -e "s/\([0-9]\+\)B/\1/g"`

		[[ "$PTYP" == "fat16" ]] && PTYP="vfat"

		MOUNT="/tmp/image-$RND/$LOOPPARTCOUNTER"
		mkdir -p $MOUNT

		trap cleanup INT

		echo "Attempting to set up partition $LOOPPARTCOUNTER on loop$LOOP with offset $POFF, size $PSZE, type ${PTYP^^}."

		losetup /dev/loop$LOOP --offset $POFF --sizelimit $PSZE "$IMG"
		mount -t $PTYP /dev/loop$LOOP $MOUNT

		LOOP=$((LOOP+1))
		LOOPPARTCOUNTER=$((LOOPPARTCOUNTER+1))

	fi

done <<< "$PARTLIST"

echo
read -n 1 -p "The image will be held open at /tmp/image-$RND until you press a key... "
echo

cleanup $LOOPINITIAL $PARTCOUNTER

exit 0
