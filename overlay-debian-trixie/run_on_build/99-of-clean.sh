#!/usr/bin/env bash

# 99-of-clean.sh v1.27 (28th March 2026)
#  Used to clean an OpenFrame.

set -e

OPTIONS=""

if [ "$(id -u)" != "0" ]; then
  echo "Must be run as root."
  exit 1
fi

# Get the kernel version.
KERNEL=`uname -r`

echo
echo "=== Wind Down ======================================="
echo
sleep 2

# Disable unwanted services.
/bin/systemctl disable e2scrub_reap.service

# Remove documentation.
echo
echo "Removing documentation and man pages..."
rm -rf /usr/share/doc /usr/share/man /usr/share/doc-base
echo

# This bit removes the development packages and source code.
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
  echo "Removing source code..."
  rm -rf /usr/src /var/lib/dkms/*
  depmod -a $KERNEL
fi

# We don't remove the keys by default for a better out-of-the-box experience, but users really should.
if [[ "$@" == "ssh" ]] || [[ "$OPTIONS" =~ "ssh" ]]; then
  echo
  echo "Removing SSH server keys..."
  rm -v /etc/ssh/ssh_host*
fi

echo
echo "Tidying the package manager..."
apt-get -y autoremove
apt-get -y clean

echo
echo "Deleting caches..."
rm -rvf /opt/squeezeplay/bin/gmon.out
rm -rvf /temp
rm -rf /var/cache/apt/*.bin
rm -rf /var/lib/apt/lists
mkdir -p /var/lib/apt/lists/partial

echo
echo "Cleaning /etc..."
rm -rvf /etc/resolv.conf
rm -rvf /etc/sqpbeta

echo
echo "Relinking systemd resolved..."
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

echo
echo "Correcting permissions..."
chown :crontab /usr/bin/crontab
chmod 2755 /usr/bin/crontab
chown :crontab /var/spool/cron/crontabs
chmod 1730 /var/spool/cron/crontabs

echo
echo "Sweeping out the root account..."
rm -rfv /root/.aptitude
rm -rfv /root/.bash_history
rm -rfv /root/.cache
rm -rfv /root/.debtags
rm -rfv /root/.local

df -h
echo
echo
echo "Cleaning complete."
echo
