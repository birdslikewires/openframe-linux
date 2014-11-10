#!/bin/bash

# ofprep.sh v1.47 (6th November 2014)
#  Set up the basics.

#set -x


OPENFRAMEUSER="joggler"


##  Things to do before installing the kernel.


echo
echo "-- Permissions and Customisation"
echo
sleep 2

echo "Generating en_GB.UTF-8 locale..."
echo
locale-gen en_GB.UTF-8
mv /etc/localtime /etc/localtime.dist
ln -s /usr/share/zoneinfo/Europe/London /etc/localtime
LANG=en_GB.UTF-8
LC_MESSAGES=POSIX
echo

echo "Creating '$OPENFRAMEUSER' user and setting policy..."
# Create user with 'joggler' as the password.
useradd -m -p sa0dkJX04f4tM -s /bin/bash $OPENFRAMEUSER
addgroup admin
adduser $OPENFRAMEUSER admin
adduser $OPENFRAMEUSER audio
adduser $OPENFRAMEUSER video
sed -i "s/OPENFRAMEUSER/$OPENFRAMEUSER/" /etc/init/tty1.conf_autologin
echo "%admin ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
echo

# This sets xterm to use the whole screen with white-on-black colouration.
echo "Setting terminal basics..."
echo -e "*xterm*geometry: 99x28\n*xterm*faceName: fixed\n*xterm*faceSize: 10\n*xterm*background: #000000\n*xterm*foreground: #f0f0f0\n*xterm*cursorColor: #f0f0f0\n*xterm*color0: #101010\n*xterm*color1: #960050\n*xterm*color2: #66aa11\n*xterm*color3: #c47f2c\n*xterm*color4: #30309b\n*xterm*color5: #7e40a5\n*xterm*color6: #3579a8\n*xterm*color7: #9999aa\n*xterm*color8: #303030\n*xterm*color9: #ff0090\n*xterm*color10: #80ff00\n*xterm*color11: #ffba68\n*xterm*color12: #5f5fee\n*xterm*color13: #bb88dd\n*xterm*color14: #4eb4fa\n*xterm*color15: #d0d0d0" > /home/$OPENFRAMEUSER/.Xdefaults
echo
echo "Running up apt-get..."
echo
sleep 4
# Always trust Jools' PPA.
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 92E73EF9
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -y --force-yes purge resolvconf ureadahead 
apt-get -y --force-yes dist-upgrade

# Here is where we add things to make a nice base.
# NB.		nfs-common 		- DO NOT add nfs-common here. It stuffs up rebooting and has to be installed once the system is live.
apt-get -y --force-yes install acpi alsa-base alsa-utils bash-completion bc dosfstools i2c-tools libbsd0 libedit2 libio-socket-ssl-perl libnet-ssleay-perl libmad0 libpango1.0-0 libvorbisidec1 libwrap0 libx11-6 libx11-data libxau6 libxcb1 libxdmcp6 libxext6 libxmuu1 linux-firmware nano openssh-server parted patch pciutils psmisc rsync ssh sudo tcpd usbutils usb-modeswitch usb-modeswitch-data unzip usbmount wget wpasupplicant wireless-tools xauth x11-xserver-utils zlibc

echo
sleep 2

echo "Clarify permissions..."
chown root:root /home
chown -R $OPENFRAMEUSER:$OPENFRAMEUSER /home/$OPENFRAMEUSER /home/$OPENFRAMEUSER/.*
chmod +s /bin/ping /bin/ping6 /bin/su /usr/bin/sudo
chown root:root /usr/local/bin/*
chmod 755 /usr/local/bin/*

echo "Fix filesystem problems automatically on boot..."
sed -i 's/FSCKFIX=no/FSCKFIX=yes/g' /etc/default/rcS

echo "Allow anyone to start the X server..."
sed -i 's/allowed_users=console/allowed_users=anybody/g' /etc/X11/Xwrapper.config

echo "Enable password authentication for root user over SSH..."
sed -i 's/PermitRootLogin without-password/PermitRootLogin yes/g' /etc/ssh/sshd_config

echo "Configure the nameservers..."
echo "append domain-name-servers 8.8.8.8, 8.8.4.4;" >> /etc/dhcp/dhclient.conf

echo "Configure usbmount..."
cp /temp/usbmount/usbmount.conf /etc/usbmount/usbmount.conf
cp /temp/usbmount/mount.d/* /etc/usbmount/mount.d/
cp /temp/usbmount/umount.d/* /etc/usbmount/umount.d/
chown root:root /etc/usbmount/mount.d/* /etc/usbmount/umount.d/*
chmod 755 /etc/usbmount/mount.d/* /etc/usbmount/umount.d/*
echo

echo "Silence initramfs..."
sed -i 's/ || echo "Loading, please wait..."//g' /usr/share/initramfs-tools/init
echo

echo "Remove SSH host keys..."
rm -v /etc/ssh/ssh_host_*
echo


## Install the kernel.


echo "-- Kernel Installation"
echo
sleep 2

KERNVER=`ls /mnt/ | grep linux-image | awk -F\- '{print $3}' | awk -F\_ '{print $1}'`

echo "Installing kernel $KERNVER..."
dpkg -i /mnt/linux-*.deb
echo

echo "Installing Intel Firmware Hub module..."
[ -d /lib/modules/$KERNVER/extra ] || mkdir /lib/modules/$KERNVER/extra
cp /temp/fh.ko /lib/modules/$KERNVER/extra/
chmod 644 /lib/modules/$KERNVER/extra/fh.ko
depmod -a $KERNVER
echo

echo "Making initrd..."
mkinitramfs -o /boot/initrd.img-$KERNVER $KERNVER 2>/dev/null
sleep 2
echo


## Wind down.


echo "-- Wind Down"
echo
sleep 2

apt-get -y --force-yes autoremove
apt-get clean
echo

echo "Linking startup and shutdown scripts..."
ln -s /etc/init.d/preptmpfs /etc/rc2.d/S10preptmpfs
ln -s /etc/init.d/logroller /etc/rc0.d/S20logroller
ln -s /etc/init.d/logroller /etc/rc6.d/S20logroller

echo "Defaulting /etc/resolv.conf..."
echo -e "nameserver 8.8.8.8\nnameserver 8.8.4.4" > /etc/resolv.conf

echo "Cleaning..."
rm -rf /etc/apparmor*
rm -rf /temp
rm -rf /var/cache/apt/*.bin
rm -rf /var/lib/apt/lists
mkdir -p /var/lib/apt/lists/partial
echo

echo "Prep complete."
exit 0
