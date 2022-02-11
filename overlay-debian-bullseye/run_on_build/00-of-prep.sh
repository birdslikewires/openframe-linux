#!/usr/bin/env bash

# 00-of-prep.sh v1.08 (10th February 2022)
#  Set up the basics.

#set -x

DLSERVER="https://birdslikewires.net/download"

OPENFRAMEUSER="of"


### Packages

echo
echo "=== Packages ========================================"
echo
sleep 2

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade

# Additions
APT_SYSTEM="acpi bash-completion bc bluez curl dosfstools e2fsprogs htop i2c-tools initramfs-tools locales libbsd0 libdaemon0 libedit2 libio-socket-ssl-perl liblockfile-bin liblockfile1 libnet-ssleay-perl libpango1.0-0 libwrap0 libx11-6 libx11-data libxau6 libxcb1 libxdmcp6 libxext6 libxmuu1 lockfile-progs lsb-release nano net-tools netplan.io ntpdate patch pciutils plymouth policykit-1 psmisc rsync sudo tcpd usbutils usb-modeswitch usb-modeswitch-data unclutter unzip uuid wget wpasupplicant wireless-tools x11-xserver-utils xauth xinput"
APT_AUDIO="alsa-utils libmad0 libvorbisidec1 libsoxr0 mpg123"
APT_SSH="ssh openssh-server"

#MISSING: libcrystalhd3 usbmount zlibc

# Removals
APT_REM_SYSTEM=""

# Make Changes
[[ "$APT_REM_SYSTEM" != "" ]] && apt-get remove -y --purge $APT_REM_SYSTEM
echo
apt-get autoremove -y
echo
apt-get install -y $APT_SYSTEM $APT_AUDIO $APT_SSH

# Install usbmount from GitHub
wget --no-check-certificate -P /tmp https://github.com/birdslikewires/usbmount/releases/download/v0.0.25/usbmount_0.0.25_all.deb
dpkg -i /tmp/usbmount_0.0.25_all.deb


### Tweaks and Permissions

echo
echo "=== Tweaks and Permissions =========================="
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

if [ "$OPENFRAMEUSER" != "root" ]; then

	echo "Creating '$OPENFRAMEUSER' user and setting policy..."
	# Create user with 'joggler' as the password.
	useradd -m -p sa0dkJX04f4tM -s /bin/bash $OPENFRAMEUSER
	addgroup admin
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

echo "Setting plymouth boot screen defaults..."
update-alternatives --remove-all default.plymouth 2>/dev/null
update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth /usr/share/plymouth/themes/tribar/tribar.plymouth 100

echo "Setting terminal preferences..."
# Colour terminal for all!
for f in `find / -iname *bashrc 2>/dev/null`; do
	sed -i 's/#force_color_prompt=yes/force_color_prompt=yes/' $f
done
echo

# Plain old-fashioned deletions.
echo "Removing unnecessary components..."
#rm -v /etc/update-motd.d/*
echo

# We use this for simple command line control of yaml files, eg. the netplan config file.
echo "Installing yq..."
curl -k -o /usr/local/bin/yq $DLSERVER/openframe/deps/yq_linux_386
echo

echo "Ensure correct permissions..."
chown root:root /home
[[ "$OPENFRAMEUSER" != "root" ]] && chown -R $OPENFRAMEUSER:$OPENFRAMEUSER $HOMEPATH $HOMEPATH/.*
chmod +s /bin/ping /bin/ping6 /bin/su /usr/bin/sudo /usr/sbin/ntpdate
#chown -R root:root /etc/polkit-1/localauthority/20-org.d
#chmod 600 /etc/polkit-1/localauthority/20-org.d/*
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
chmod +x /usr/local/sbin/of-*
chmod +x /usr/sbin/*
for f in `ls -1 /lib/systemd/system | grep 'of-' | grep '.service'`; do
  SERVICE=`echo $f | awk -F\.service {'print $1'}`
  /bin/systemctl enable $SERVICE
  echo "Enabled $SERVICE"
done
echo

echo "Enable password authentication for root user over SSH..."
[[ "$OPENFRAMEUSER" == "root" ]] && echo "PermitRootLogin yes" >> /etc/ssh/sshd_config


echo "Configure usbmount..."
cp /temp/usbmount/usbmount.conf /etc/usbmount/usbmount.conf
cp /temp/usbmount/mount.d/* /etc/usbmount/mount.d/
cp /temp/usbmount/umount.d/* /etc/usbmount/umount.d/
chown root:root /etc/usbmount/mount.d/* /etc/usbmount/umount.d/*
chmod 755 /etc/usbmount/mount.d/* /etc/usbmount/umount.d/*
echo


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

# KERNELURL="$DLSERVER/openframe/kernel/$KERNMAJVER.$KERNMIDVER/$KERNVER"
# echo "Checking $KERNELURL for companion modules..."
# if curl -k -f "$KERNELURL/modules-$KERNVER.tgz" >/dev/null 2>&1; then
# 	echo
# 	echo "Found additional modules on $DLSERVER for $KERNVER. Downloading and installing."
# 	echo
# 	curl -k -o /modules-$KERNVER.tgz "$KERNELURL/modules-$KERNVER.tgz"
# 	if [ -f /modules-$KERNVER.tgz ]; then
# 		tar zxvf /modules-$KERNVER.tgz -C /
# 		rm /modules-$KERNVER.tgz
# 	fi
# else
# 	echo
# 	echo "No additional modules found."
# 	echo
# fi

# depmod -a $KERNVER
# echo


### Wind Down

echo
echo "=== Wind Down ======================================="
echo
sleep 2

apt-get -y autoremove
apt-get clean
echo

echo "Cleaning..."
rm -rf /etc/apparmor*
rm -rf /temp
rm -rf /var/cache/apt/*.bin
rm -rf /var/lib/apt/lists
mkdir -p /var/lib/apt/lists/partial
echo

echo "Remove SSH host keys..."
rm -v /etc/ssh/ssh_host_*
echo

echo "Prep complete."
exit 0
