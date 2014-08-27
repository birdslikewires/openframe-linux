#!/bin/bash

# ofimgmnt.sh v1.00 (20th August 2014)
#  For mounting an image file.

#set -x

# Which loops to use (should be automatic, but meh).
BL=6
RL=7

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

## Variabilities

PARTINFO=`parted -m "$1" unit b print`

PARTCHECK=`echo "$PARTINFO" | wc -l`
[ $PARTCHECK -ne 4 ] && echo "Unexpected number of partitions. We can only handle two!" && exit 1

BOFF=`echo "$PARTINFO" | grep "^1" | cut -d: -f 2 | sed -e "s/\([0-9]\+\)B/\1/g"`
BSZE=`echo "$PARTINFO" | grep "^1" | cut -d: -f 4 | sed -e "s/\([0-9]\+\)B/\1/g"`

ROFF=`echo "$PARTINFO" | grep "^2" | cut -d: -f 2 | sed -e "s/\([0-9]\+\)B/\1/g"`
RSZE=`echo "$PARTINFO" | grep "^2" | cut -d: -f 4 | sed -e "s/\([0-9]\+\)B/\1/g"`
RTYP=`echo "$PARTINFO" | grep "^2" | cut -d: -f 5 | sed -e "s/\([0-9]\+\)B/\1/g"`

RND=$RANDOM
BMP="/tmp/image-$RND/boot" && mkdir -p $BMP
RMP="/tmp/image-$RND/root" && mkdir -p $RMP

## Do Stuff

cleanup() {
  trap '' INT
  umount $BMP
  umount $RMP
  rm -rf /tmp/image-$RND
  losetup -d /dev/loop$BL
  losetup -d /dev/loop$RL
  echo
  echo "Finished."
  exit
}

trap cleanup INT

losetup /dev/loop$BL --offset $BOFF --sizelimit $BSZE "$1"
losetup /dev/loop$RL --offset $ROFF --sizelimit $RSZE "$1"

mount -t vfat /dev/loop$BL $BMP
mount -t $RTYP /dev/loop$RL $RMP

read -n 1 -p "The image will be held open at /tmp/image-$RND until you press a key... "

cleanup
