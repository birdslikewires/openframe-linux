#!/usr/bin/env bash

# 00-of-prep.sh v1.18 (3rd September 2025)
#  Set up the basics.

#set -x


OPENFRAMEUSER="of"


### Packages

echo
echo "=== Packages ========================================"
echo
sleep 2

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade

# Additions
APT_SYSTEM="acpi bash-completion bc ca-certificates curl dosfstools e2fsck-static e2fsprogs firmware-realtek htop i2c-tools initramfs-tools inotify-tools locales libbsd0 libdaemon0 libedit2 libio-socket-ssl-perl liblockfile-bin liblockfile1 libnet-ssleay-perl libpango-1.0-0 libwrap0 libx11-6 libx11-data libxau6 libxcb1 libxdmcp6 libxext6 libxmuu1 lockfile-progs lsb-release nano net-tools netplan.io ntpsec-ntpdate openssl patch pciutils plymouth psmisc rsync sudo systemd-resolved systemd-timesyncd tcpd usbutils usb-modeswitch usb-modeswitch-data unzip uuid wget wpasupplicant wireless-regdb wireless-tools x11-xserver-utils xauth xinput zstd"
APT_AUDIO="alsa-utils libmad0 libvorbisidec1 libsoxr0 mpg123"
APT_SSH="ssh openssh-server"

# Removals
APT_REM_SYSTEM=""

# Make Changes
[[ "$APT_REM_SYSTEM" != "" ]] && apt-get remove -y --purge $APT_REM_SYSTEM
echo
apt-get autoremove -y
echo
apt-get install -y $APT_SYSTEM $APT_AUDIO $APT_SSH


### Tweaks and Permissions

echo
echo "=== Tweaks and Permissions =========================="
echo
sleep 2

echo "Generating en_GB.UTF-8 locale..."
echo
sed -i 's/^# *\(en_GB.UTF-8\)/\1/' /etc/locale.gen
locale-gen en_GB.UTF-8
mv /etc/localtime /etc/localtime.dist
ln -s /usr/share/zoneinfo/Europe/London /etc/localtime
LANG=en_GB.UTF-8
LC_MESSAGES=POSIX
echo

if [ "$OPENFRAMEUSER" != "root" ]; then

	echo "Creating '$OPENFRAMEUSER' user and setting policy..."
	# Create user with 'joggler' as the password.
	useradd -m -p sa0dkJX04f4tM -s /bin/bash $OPENFRAMEUSER
	addgroup admin
	adduser $OPENFRAMEUSER adm
	adduser $OPENFRAMEUSER admin
	adduser $OPENFRAMEUSER audio
	adduser $OPENFRAMEUSER sudo
	adduser $OPENFRAMEUSER tty
	adduser $OPENFRAMEUSER users
	adduser $OPENFRAMEUSER video
	HOMEPATH="/home/$OPENFRAMEUSER"
	echo

else

	echo "root:joggler" | chpasswd
	HOMEPATH="/root"

fi

echo "Setting terminal preferences..."
# Colour terminal for all!
for f in `find / -iname *bashrc 2>/dev/null`; do
	sed -i 's/#force_color_prompt=yes/force_color_prompt=yes/' $f
done

# Sets the chassis type.
/usr/bin/hostnamectl chassis embedded

# Allows clearing of tty1 when IP address is updated.
sed -i 's/\-\-noreset \-\-noclear //g' /usr/lib/systemd/system/getty@.service

echo

# Plain old-fashioned deletions.
#echo "Removing unnecessary components..."
#rm -v /etc/update-motd.d/*
#echo

echo "Ensure correct permissions..."
[[ "$OPENFRAMEUSER" != "root" ]] && chown -R $OPENFRAMEUSER:$OPENFRAMEUSER $HOMEPATH $HOMEPATH/.*
chown root:root /home
chmod +s /bin/ping /bin/ping6 /bin/su /usr/bin/sudo /usr/sbin/ntpdate
chown -R root:root /etc/sudoers.d
chmod -R 440 /etc/sudoers.d/*
chown root:root /usr/local/bin/*
chown root:root /usr/local/sbin/*
chmod 755 /usr/local/bin/*
chmod 755 /usr/local/sbin/*
chmod 644 /usr/local/sbin/*.ver
echo

echo "Enable systemd services..."
/bin/systemctl enable systemd-resolved.service
/bin/systemctl enable systemd-timesyncd.service
chmod +x /usr/local/sbin/of-*
chmod +x /usr/sbin/*
for f in `ls -1 /etc/systemd/system | grep 'of-' | grep '.service'`; do
  SERVICE=`echo $f | awk -F\.service {'print $1'}`
  /bin/systemctl enable $SERVICE
  echo "Enabled $SERVICE"
done
echo

echo "Enable password authentication for root user over SSH..."
[[ "$OPENFRAMEUSER" == "root" ]] && echo "PermitRootLogin yes" >> /etc/ssh/sshd_config


### Kernel Installation

echo
echo "=== Kernel Installation ============================="
echo
sleep 2

KERNVER=`ls /mnt/ | grep linux-image | awk -F\- '{print $3}' | awk -F\_ '{print $1}'`
KERNMAJVER=`echo $KERNVER | awk -F\. {'print $1'}`
KERNMIDVER=`echo $KERNVER | awk -F\. {'print $2'}`
KERNMINVER=`echo $KERNVER | awk -F\. {'print $3'}`

source /etc/os-release

echo "Installing kernel $KERNVER into ${VERSION_CODENAME^} chroot..."
dpkg -i /mnt/linux-image*.deb
echo

exit 0
