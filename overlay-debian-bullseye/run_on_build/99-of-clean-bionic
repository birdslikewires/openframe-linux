#!/usr/bin/env bash

# 99-of-clean-bionic v1.23 (3rd September 2018)
#  Used to clean an OpenFrame.

OPTIONS=""

if [ "$USER" != "root" ]; then
  echo "Must be run as root."
  exit
fi

# Get the kernel version.
CHROOTKERN=`ls /mnt/ | grep linux-image`
if [ "$CHROOTKERN" != "" ]; then
  KERNEL=`ls /mnt/ | grep linux-image | awk -F\- '{print $3}' | awk -F\_ '{print $1}'`
else
  KERNEL=`uname -r`
fi

# This bit removes the development packages, source code and man files.
if [[ "$@" == "dev" ]] || [[ "$OPTIONS" =~ "dev" ]]; then
  echo
  if [ -d /lib/modules/$KERNEL/updates/dkms ]; then
    echo "Backing up DKMS kernel modules..."
    mv /lib/modules/$KERNEL/updates/dkms /lib/modules/$KERNEL/updates/dkms.bak
  fi
  echo "Removing development packages and source code..."
  apt-get -y remove build-essential dkms eject fakeroot gcc libc-dev-bin libc6-dev libgomp1 libquadmath0 libxft2 linux-headers-$KERNEL linux-libc-dev make manpages manpages-dev rt2870sta-dkms 2>/dev/null
  echo
  if [ -d /lib/modules/$KERNEL/updates/dkms ]; then
    echo "Restoring previously installed DKMS kernel modules..."
    mv /lib/modules/$KERNEL/updates/dkms.bak /lib/modules/$KERNEL/updates/dkms
  fi
  echo "Removing man files and example code..."
  rm -rf /usr/src /usr/share/doc /usr/share/man /usr/share/doc-base /usr/share/sounds/alsa/* /var/lib/dkms/*
  depmod -a $KERNEL
fi

if [[ "$@" == "ssh" ]] || [[ "$OPTIONS" =~ "ssh" ]]; then
  echo
  echo "Removing SSH server keys..."
  rm /etc/ssh/ssh_host*
fi

echo
echo "Tidying the package manager..."
apt-get -y autoremove
apt-get -y clean

echo
echo "Deleting caches..."
rm -rvf /opt/squeezeplay/bin/gmon.out

echo
echo "Cleaning /etc..."
rm -rvf /etc/sqpbeta

echo
echo "Sweeping out the root account..."
rm -rfv /root/.aptitude
rm -rfv /root/.bash_history
rm -rfv /root/.cache
rm -rfv /root/.debtags
rm -rfv /root/.local

echo
echo
[[ "$CHROOTKERN" == "" ]] && df -h
echo
echo
echo "Cleaning complete."
echo
