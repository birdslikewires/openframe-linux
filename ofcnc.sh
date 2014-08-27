#!/bin/bash

# ofcnc.sh v1.14 (20th August 2014)
#  Used to clean 'n' copy a Joggler OS from a storage device.

#set -x

if [ $USER != "root" ]; then
  echo "Must be run as root."
  exit
fi

if [ "$#" -lt 3 ]; then
  echo "$0 <boot> <root> [destdir] [compress]"
  echo
  echo "boot:     Boot mountpoint, eg. /media/jog-boot/"
  echo "root:     Root mountpoint, eg. /media/jog-root/"
  echo "destdir:  Directory to output filesystem to. Will be created if necessary."
  echo "compress: Integer 0 or 1. Compresses filesystem and deletes directory."
  exit
else
  JB="$1"
  JR="$2"
  DS="$3"
  CM="$4"
fi


# Cleaning happens first.
echo
echo -n "Cleaning $JR..."
sleep 2
echo

echo
echo "Deleting cache stuff first..."
rm -v $JR/var/cache/apt/*.bin 2>/dev/null
rm -rvf $JR/var/lib/apt/lists 2>/dev/null
mkdir -p $JR/var/lib/apt/lists/partial
rm -v $JR/var/lib/aptitude/*.old 2>/dev/null
rm -v $JR/var/lib/dpkg*-old 2>/dev/null
rm -v $JR/var/cache/debconf/*-old 2>/dev/null
rm -v $JR/opt/squeezeplay/bin/gmon.out 2>/dev/null

echo
echo "Removing MAC address, udev and other /etc stuff..."
rm -rvf $JR/etc/apparmor* 2>/dev/null
rm -v $JR/etc/*-old 2>/dev/null
rm -v $JR/etc/init/*_old 2>/dev/null
rm -v $JR/etc/network/joggler-eth 2>/dev/null
rm -v $JR/etc/sqpbeta 2>/dev/null
rm -v $JR/etc/udev/rules.d/70-persistent-cd.rules 2>/dev/null
rm -v $JR/etc/udev/rules.d/70-persistent-net.rules 2>/dev/null
touch $JR/etc/udev/rules.d/70-persistent-net.rules

echo
echo "Removing SSH server keys..."
rm -v /etc/ssh/ssh_host*

# Tidy up /etc/resolv.conf
echo
echo "Emptying /etc/resolv.conf..."
echo -e "nameserver 8.8.8.8\nnameserver 8.8.4.4" > $JR/etc/resolv.conf

echo
echo "Resetting user accounts..."
rm -rfv $JR/home/joggler/.*_old 2>/dev/null
rm -rfv $JR/home/joggler/.aptitude 2>/dev/null
rm -rfv $JR/home/joggler/.bash_history 2>/dev/null
rm -rfv $JR/home/joggler/.cache 2>/dev/null
rm -rfv $JR/home/joggler/.debtags 2>/dev/null
rm -rfv $JR/home/joggler/.nano_history 2>/dev/null
rm -rfv $JR/home/joggler/.sudo_as_admin_successful 2>/dev/null
rm -rfv $JR/home/joggler/.squeezeplay 2>/dev/null
rm -rfv $JR/root/.aptitude 2>/dev/null
rm -rfv $JR/root/.bash_history 2>/dev/null
rm -rfv $JR/root/.cache 2>/dev/null
rm -rfv $JR/root/.debtags 2>/dev/null
rm -rfv $JR/root/.nano_history 2>/dev/null


echo
echo "Removing log files..."
rm -rfv $JR/var/logroll.tgz 2>/dev/null
rm -rfv $JR/var/log/* 2>/dev/null


if [ "$#" -lt 3 ]; then
  echo
  echo "Cleaning complete."
  exit 0
fi


## Stuff after here only happens if more than 3 arguments passed.

# Now for the copying.
echo
echo "Output will be to ./$DS..."
[ -d $DS ] && rm -rf $DS
[ -f $DS.tgz ] && rm -rf $DS.tgz
sync
sleep 2
[ -d $DS ] || mkdir $DS
mkdir $DS/boot
mkdir $DS/root
echo
echo -n "Copying root..."
rsync -a $JR $DS/root/
echo " done."
echo -n "Copying boot..."
cp -R $JB/* $DS/boot/
echo " done."

if [ "$CM" == "1" ]; then
	echo -n "Compressing..."
	tar zcf $DS.tgz $DS/root $DS/boot
	sleep 2
	rm -rf $DS
	echo " done."
	echo
	echo "Compressed to $DS.tgz"
fi
