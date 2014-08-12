#!/bin/bash

# ofprep.sh v1.39 (29th January 2014)
#  Sets some basics and cleans up a fresh install from debootstrap.

#set -x

## Locale generation.
echo "-- Generating en_GB.UTF-8 locale..."
echo
locale-gen en_GB.UTF-8
mv /etc/localtime /etc/localtime.dist
ln -s /usr/share/zoneinfo/Europe/London /etc/localtime
LANG=en_GB.UTF-8
LC_MESSAGES=POSIX
sleep 2

## Creating the 'joggler' user with 'joggler' as the password.
echo
echo "-- Creating user and setting policy..."
useradd -m -p sa0dkJX04f4tM -s /bin/bash joggler
addgroup admin
adduser joggler admin
adduser joggler audio
adduser joggler video
# This sets xterm to use the whole screen with white-on-black colouration.
echo -e "*xterm*geometry: 99x28\n*xterm*faceName: fixed\n*xterm*faceSize: 10\n*xterm*background: #000000\n*xterm*foreground: #f0f0f0\n*xterm*cursorColor: #f0f0f0\n*xterm*color0: #101010\n*xterm*color1: #960050\n*xterm*color2: #66aa11\n*xterm*color3: #c47f2c\n*xterm*color4: #30309b\n*xterm*color5: #7e40a5\n*xterm*color6: #3579a8\n*xterm*color7: #9999aa\n*xterm*color8: #303030\n*xterm*color9: #ff0090\n*xterm*color10: #80ff00\n*xterm*color11: #ffba68\n*xterm*color12: #5f5fee\n*xterm*color13: #bb88dd\n*xterm*color14: #4eb4fa\n*xterm*color15: #d0d0d0" > /home/joggler/.Xdefaults
echo "%admin ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
sleep 2
echo

## Set up apt-get with PPAs and install a few things.
echo "-- Running up apt-get..."
echo
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 92E73EF9
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -y --force-yes purge resolvconf ureadahead 
apt-get -y --force-yes dist-upgrade

## Here is where we add things to make a nice base.
##
# - nfs-common 		- DO NOT add nfs-common here. It stuffs up rebooting and has to be installed once the system is live.
apt-get -y --force-yes install acpi alsa-base alsa-utils bash-completion dosfstools i2c-tools libbsd0 libedit2 libmad0 libpango1.0-0 libvorbisidec1 libwrap0 libx11-6 libx11-data libxau6 libxcb1 libxdmcp6 libxext6 libxmuu1 nano openssh-server parted patch pciutils psmisc rsync ssh sudo tcpd usbutils usb-modeswitch usb-modeswitch-data unzip usbmount wget wpasupplicant wireless-tools xauth x11-xserver-utils zlibc
##

sleep 2
echo

## Permission twiddling
echo "-- Tweak permissions..."
chown root:root /home
chown -R joggler:joggler /home/joggler /home/joggler/.*
chmod +s /bin/ping /bin/ping6 /bin/su /usr/bin/sudo 
sleep 2
echo


## Remedial work
##  Do this before installing the kernel, as some of these things end up in initramfs
echo "-- Remedial work..."
echo "Set fsck to fix problems automatically on boot..."
sed -i 's/FSCKFIX=no/FSCKFIX=yes/g' /etc/default/rcS

echo "Set X to allow anyone to start the server..."
sed -i 's/allowed_users=console/allowed_users=anybody/g' /etc/X11/Xwrapper.config

echo "Configure the nameservers..."
echo "append domain-name-servers 8.8.8.8, 8.8.4.4;" >> /etc/dhcp/dhclient.conf

echo "Patch /lib/udev/rules.d/60-persistent-storage.rules to NOT check USB devices with ata_id..."
patch /lib/udev/rules.d/60-persistent-storage.rules < /temp/patches/60-persistent-storage.patch

echo "Remove pre-configured SSH host keys..."
rm -v /etc/ssh/ssh_host_*
echo


## Install the kernel
echo "-- Installing kernel $KERNVER..."
KERNVER=`ls /mnt/ | grep linux-image | awk -F\- '{print $3}' | awk -F\_ '{print $1}'`
dpkg -i /mnt/linux-*.deb
mkinitramfs -o /boot/initrd.img-$KERNVER $KERNVER
sleep 2
echo

## Install firmware files
##  Latest version fetched from https://launchpad.net/ubuntu/+source/linux-firmware
echo "-- Installing NIC firmware files..."
dpkg -i /temp/nic-firmware*
update-initramfs -u
echo

# Wind down apt-get
apt-get -y --force-yes autoremove
apt-get clean
echo

# Link up the tmpfs scripts
echo "-- Linking tmpfs scripts..."
ln -s /etc/init.d/preptmpfs /etc/rc2.d/S40preptmpfs
ln -s /etc/init.d/logroller /etc/rc0.d/S20logroller
ln -s /etc/init.d/logroller /etc/rc6.d/S20logroller

# Tidy up /etc/resolv.conf
echo "-- Emptying /etc/resolv.conf..."
echo -e "nameserver 8.8.8.8\nnameserver 8.8.4.4" > /etc/resolv.conf

# Cleaning
echo "-- Cleaning..."
rm -rf /etc/apparmor*
rm -rf /temp
rm -rf /var/cache/apt/*.bin
rm -rf /var/lib/apt/lists
mkdir -p /var/lib/apt/lists/partial

exit 0





