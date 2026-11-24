#!/usr/bin/env bash

# ofimgcreate v26.11.4 (16th November 2026)
#  Used to prepare an OpenFrame image file from a .tgz or using debootstrap.

#set -x

countdown() {
	local i
	echo -n $1
	sleep 1
	for ((i = $1 - 1; i >= 1; i--)); do
		printf "\b%d" $i
		sleep 1
	done
	printf "\b\b\b\bnow..."
}

if [[ "$#" -lt 5 ]]; then
	echo "Usage: $0 <name> <filesystem> <totalMB> <bootMB> <source> [overlay] [kerneldir]"
	echo
	echo "  name:            System name. Will be used for filename and partition prefix."
	echo "  filesystem:      ext4 (journaled, recommended: it shrugs off power cuts), ext2 or btrfs."
	echo "  totalMB:         The total size of the image file; specify 'of1' or 'of2' for respective internal MMC."
	echo "  bootMB:          The size of the FAT16 boot volume (32 MB minimum, for the initrd; the"
	echo "                   images use 68, a 64 MiB volume, for a kernel kept to fall back on too)."
	echo
	echo "  Images start the kernel directly from the firmware's shell, with an initrd. From its first"
	echo "  boot the system leaves the initrd out whenever it can (of-bootnsh). An image for the"
	echo "  internal memory (of1, of2) keeps GRUB as the safety net for firmware that can't load the"
	echo "  kernel from there."
	echo "  source:          Source of operating system, MUST BE QUOTED. You have two options here:"
	echo "                      1) Give an official distro name and code name, eg. 'ubuntu bionic'."
	echo "                      2) Point to a local .tgz file containing boot and root structures."
	echo
	echo "  overlay:         Location of overlay files to be copied (required when using distro name and code name as source)."
	echo "  kerneldir:       Location of linux-image and linux-header packages (required when using distro name and code name as source)."
	echo "  server:          Package download URL (required when using distro name and code name as source)."
	echo
	exit 0
fi

if [ "$(id -u)" != "0" ]; then
	echo "You need to run this with superuser privileges."
	exit 1
fi

DBPRESENT=$(which debootstrap)
if [ "$DBPRESENT" == "" ]; then
	echo "You need to install debootstrap for this to work."
	exit 1
fi

NAME="${1^^}"
FS="${2}"
if [ "$FS" == "ext3" ] || [ "$FS" == "ext3" ]; then
	echo "We don't support $FS. Setting to ext2 instead."
	FS="ext2"
fi
if [ "$FS" == "btrfs" ]; then
	echo "Our btrfs methods are broken. Setting to ext2 instead."
	FS="ext2"
fi

TSIZE="${3}"
OFVARIANT="${3}"
BSIZE="${4}"

## If 'of1' or 'of2' is given for size, create an image that exactly matches the OpenFrame 1 or 2 internal storage.
##  On the OpenFrame1 we override the boot partition size to 32MB. This is the minimum size that still allows update-initramfs to work.
if [[ "$TSIZE" == "of1" ]]; then

	BYTESSIZE="1028128768"
	TSIZE="1028"

	if [ $BSIZE -eq 0 ]; then
		BSIZE="32"
		echo
		echo "OpenFrame 1 boot size set to minimum for initramfs ($BSIZE MB)."
	fi

elif [[ "$TSIZE" == "of2" ]]; then

	BYTESSIZE="2055208960"
	TSIZE="2055"

elif [[ "$TSIZE" == "uni" ]]; then

	BYTESSIZE="1028128768"
	TSIZE="1028"

else

	BYTESSIZE="0"

	if [ $BSIZE -lt 32 ]; then
		BSIZE="32"
		echo
		echo "Specified boot size too small; overridden to $BSIZE MB to accommodate initramfs."
	fi

fi

INSTALL="${5}"
DISTNAME=$(echo "$INSTALL" | awk -F\  {'print $1'})
CODENAME=$(echo "$INSTALL" | awk -F\  {'print $2'})
INSTALL="$CODENAME"
OVERLAY="${6}"
KERNELDIR="${7}"
DBSERVER="${8}"
RSIZE=$(($TSIZE - $BSIZE))

if [[ ! "$INSTALL" =~ "tgz" ]] && [[ "$DBSERVER" == "" ]]; then
	echo "You have not provided a download server or a .tgz to work from."
	echo "Perhaps you need one of these:"
	echo
	echo "  http://ftp.uk.debian.org/debian/"
	echo "  http://gb.archive.ubuntu.com/ubuntu/"
	echo
	exit 1
fi

if [[ "$INSTALL" != "" ]] && [[ ! "$INSTALL" =~ "tgz" ]] && [[ "$#" -lt 7 ]] && [ ! -d "$INSTALL" ]; then
	echo "An overlay is required for a working system."
	echo "You will have a raw debootstrap system with no kernel and"
	echo "no OpenFrame customisations."
	echo
	echo "Press CTRL-C to exit if this is not what you had in mind."
	sleep 10
	echo
	echo "Okay, continuing..."
	echo
fi

# Warning if things are a bit tight on space.
if [[ "$INSTALL" != "" ]] && [[ ! "$INSTALL" =~ "tgz" ]] && [[ "$RSIZE" -le "512" ]]; then
	echo
	echo "Your root size will be "$RSIZE"MB"
	echo "This might be a tight squeeze. Watch out for space-related problems."
	echo
fi

# Sort out the filenames.
if [[ "$INSTALL" != "" ]] && [[ "$KERNELDIR" != "" ]]; then
	KERNVER=$(ls $KERNELDIR | grep linux-image | awk -F\- '{print $3}' | awk -F\_ '{print $1}')
	FILENAME="${NAME,,}-$FS-$TSIZE-$BSIZE-$INSTALL-$KERNVER.img"
elif [[ "$INSTALL" != "" ]] && [[ ! "$INSTALL" =~ "tgz" ]] && [[ ! -d "$INSTALL" ]]; then
	FILENAME="${NAME,,}-$FS-$TSIZE-$BSIZE-$INSTALL.img"
else
	if [[ "$INSTALL" =~ "tgz" ]]; then
		CLONENAME=$(echo $INSTALL | awk -F\. {'print $1'})
	else
		CLONENAME="${NAME,,}"
	fi
	FILENAME="$CLONENAME"_"$OFVARIANT".img
fi

FILEWARN=$(ls | grep -c "$FILENAME")
if [[ "$FILEWARN" != "0" ]]; then
	echo
	echo "There is already a file called '$FILENAME' in this location!"
	echo
	echo -n "Press CTRL-C to exit, or we'll erase it and continue in "
	countdown 9
	sleep 1
	echo -n " "
	rm -v $FILENAME
	sleep 1
fi

echo
if [[ "$INSTALL" =~ "tgz" ]]; then
	echo "Creating image from tarball..."
elif [[ -d "$INSTALL" ]]; then
	echo "Creating image from existing directory structure contained in $INSTALL..."
else
	echo "Creating image from debootstrap..."
fi
echo

echo "Image filename will be: $FILENAME"
echo
sleep 1

# Set up the debootstrap cache and build directory names.
DBSLOC=$INSTALL"_dbscache"
BLDLOC=$INSTALL"-"${NAME,,}"-openframe-"$KERNVER

# Impose name character limit. Too long and the label will be truncated.
if [[ ${#NAME} > 5 ]]; then
	echo "Name prefix must be 5 characters or fewer."
	exit 0
else
	RNAME="$NAME"-ROOT
	BNAME="$NAME"-BOOT
	echo "Partitions will be:"
	echo "  boot: $BNAME"
	echo "        ("$BSIZE"MB)"
	echo "  root: $RNAME"
	echo "        ("$RSIZE"MB)"
	echo
	sleep 4
fi

partitions_create() {
	# /boot starts at 1 MiB, the usual alignment for flash storage, and root where it
	# always has: the first MiB boundary at or after $BSIZE MB. Until November 2026
	# /boot started at sector 1, which put the partition table and the start of its
	# FAT in the same 4 KB: writing the table on a running system could put back an
	# old copy of the FAT (see of-identifier).
	BOOTEND=$(( (BSIZE * 1000000 + 1048575) / 1048576 ))

	parted -s "$FILENAME" -- \
		mklabel msdos \
		mkpart primary fat16 1MiB ${BOOTEND}MiB \
		set 1 boot on \
		mkpart primary ${BOOTEND}MiB -1 || die "parted couldn't partition $FILENAME."

	sync
	sleep 2
}

get_part_byte_offset() {
	PART=$1
	OFF=$(($2 + 1))
	parted -m "$FILENAME" unit b print | grep "^$PART" | cut -d: -f $OFF | sed -e "s/\([0-9]\+\)B/\1/g"
}

# loop#, partition
loop_create() {
	# Create our own loop devices so we're not in competition with anyone.
	if [ ! -e /dev/of-loop0 ]; then
		mknod /dev/of-loop0 b 7 200
		mknod /dev/of-loop1 b 7 201
	fi
	OFFSET=$(get_part_byte_offset $2 1)
	SIZE=$(get_part_byte_offset $2 3)
	losetup /dev/of-loop$1 --offset $OFFSET --sizelimit $SIZE "$FILENAME" || die "couldn't attach partition $2 to /dev/of-loop$1 (is it still in use?)."
}

loop_delete() {
	losetup -d /dev/of-loop$1
}

filesystems_create() {
	mkfs.vfat -F 16 -n "$BNAME" /dev/of-loop0 || die "couldn't make the boot filesystem."

	ROOTLOOP="/dev/of-loop1"

	case $1 in
	btrfs)
		echo "Btrfs configuration."
		MKFS="mkfs.btrfs -m single"
		TUNEFS=""
		FSCK=""
		;;
	ext2)
		echo "ext2 configuration."
		MKFS="mkfs.ext2"
		TUNEFS="tune2fs -i 0 $ROOTLOOP"
		FSCK="e2fsck -f -n $ROOTLOOP"
		;;
	ext4)
		# With a journal, a power cut costs a moment's replay at the next mount instead of
		# a full check. 32 MB is plenty for this workload.
		echo "ext4 configuration."
		MKFS="mkfs.ext4 -J size=32"
		TUNEFS="tune2fs -i 0 $ROOTLOOP"
		FSCK="e2fsck -f -n $ROOTLOOP"
		;;
	esac

	$MKFS -L "$RNAME" $ROOTLOOP || die "couldn't make the root filesystem."
	$TUNEFS
	sync
	sleep 2
	# Checked only (-n): with no terminal, as in CI, e2fsck won't repair, and on a filesystem
	# made a moment ago anything to repair is a fault. 0 is clean.
	if [ -n "$FSCK" ]; then $FSCK; [ $? -eq 0 ] || die "the new root filesystem doesn't check."; fi
	sync
	sleep 2
}

mmc_cfg() {
	if [[ "$OFVARIANT" == "of1" ]] || [[ "$OFVARIANT" == "of2" ]]; then
		echo
		echo -n "Configuring internal memory boot settings..."

		# fstab and grub.cfg keep naming the partitions by label: the internal memory's
		# kernel name varies (mmcblk0, 1 or 2), and first boot (of-identifier) gives
		# them unique identifiers. Stock firmware can only start the kernel from the
		# internal memory after BlwMmcFix.efi, and firmware it doesn't recognise not
		# at all, so boot.nsh has GRUB after it (of-bootnsh).
		if [ -f $MP/usr/local/sbin/of-bootnsh ]; then
			bash $MP/usr/local/sbin/of-bootnsh stub mmc $MP/boot >/dev/null || die "of-bootnsh couldn't write boot.nsh."
		fi

		echo " done."
	fi
}

# The host's /dev, /proc, /sys, /tmp and kernel directory, bound into the build directory
# for its chroot, taken out again: whichever are still there.
unbind_chroot() {
	local D
	for D in mnt tmp sys proc dev/pts dev; do
		if mountpoint -q "$BLDLOC/$D" 2>/dev/null; then
			umount "$BLDLOC/$D" 2>/dev/null || umount -l "$BLDLOC/$D"
		fi
	done
}

# True if nothing at all is mounted under the build directory. It's removed with rm -rf,
# which would otherwise go on into the host's /dev and /tmp and the kernel packages (a
# chroot step that failed used to leave them bound there, for the next run to find).
bldloc_unmounted() {
	! findmnt -rn -o TARGET | grep -q "^${BLDLOC%/}/"
}

cleanup() {
	trap '' INT
	sleep 5
	umount $MP/boot
	if [[ "$OVERLAY" != "" ]] && [[ "$KERNELDIR" != "" ]]; then
		umount $BLDLOC/mnt
		umount $BLDLOC/tmp
		umount $BLDLOC/sys
		umount $BLDLOC/proc
		umount $BLDLOC/dev/pts
		umount $BLDLOC/dev
	fi
	umount $MP
	rmdir $MP
	loop_delete 0 2>/dev/null
	loop_delete 1 2>/dev/null
	echo
	echo "Creation of $FILENAME is complete."
	echo
	exit
}

## Let's get underway...
# Stops the build: says what went wrong, takes out whatever is still bound or mounted,
# detaches the loops, and exits non-zero, so nothing goes on to publish the image. (The
# script has no 'set -e': plenty of what it runs may fail harmlessly, so the steps that
# matter are checked one by one.)
die() {
	trap '' INT
	echo
	echo "Error: $*"
	[ -n "${BLDLOC:-}" ] && unbind_chroot
	if [ -n "${MP:-}" ]; then
		umount "$MP/boot" 2>/dev/null
		umount "$MP" 2>/dev/null
		rmdir "$MP" 2>/dev/null
	fi
	loop_delete 0 2>/dev/null
	loop_delete 1 2>/dev/null
	exit 1
}

# The finished image, checked before it's closed, so a build that went wrong without
# saying so isn't published: the boot volume starts the kernel (boot.nsh, the kernel, its
# initrd), the root has a system with our scripts in it, and no SSH host keys (each unit
# makes its own: see run_on_build/99-of-clean.sh).
image_check() {
	local f
	grep -qE '^[[:space:]]*(vmlinuz|grubq)' "$MP/boot/boot.nsh" 2>/dev/null || die "the image's boot.nsh doesn't start the kernel."
	[ -s "$MP/boot/vmlinuz.efi" ] || die "the image has no kernel (boot/vmlinuz.efi)."
	ls "$MP"/boot/initrd.img-* > /dev/null 2>&1 || die "the image has no initrd."
	for f in boot/startup.nsh boot/grub.cfg etc/os-release etc/fstab usr/local/sbin/of-bootnsh usr/local/sbin/of-netplan; do
		[ -s "$MP/$f" ] || die "the image has no $f."
	done
	! ls "$MP"/etc/ssh/ssh_host_* > /dev/null 2>&1 || die "the image has SSH host keys in it: every unit would share them."
	echo "The image's boot files and system are there."
}

trap cleanup INT

# Make the image file.
echo "Creating "$TSIZE"MB image file..."
if [ "$BYTESSIZE" != "0" ]; then
	BYTESSIZE=$(($BYTESSIZE / 8))
	dd if=/dev/zero of="$FILENAME" bs=$BYTESSIZE count=8 || die "couldn't make $FILENAME."
else
	dd if=/dev/zero of="$FILENAME" bs=1MB count=$TSIZE || die "couldn't make $FILENAME."
fi
sync
sync
sync
sleep 5
echo
echo "Creating partitions..."
partitions_create $FS
echo
echo "Creating filesystems..."
loop_create 0 1
loop_create 1 2
filesystems_create $FS

# Create mount points.
MP=./tmp/img$RANDOM
mkdir -p $MP
echo
echo "Mounting image file as $MP..."

case $FS in
btrfs)
	MOUNTOPTS="compress,noatime"
	;;
ext2)
	MOUNTOPTS="errors=remount-ro,noatime"
	;;
ext4)
	MOUNTOPTS="errors=remount-ro,noatime"
	;;
esac

# Mount the image file.
mount -t $FS -o $MOUNTOPTS /dev/of-loop1 $MP || die "couldn't mount the image's root filesystem."
mkdir $MP/boot
umount /dev/of-loop0 2>/dev/null
sleep 4
mount -t vfat /dev/of-loop0 $MP/boot || die "couldn't mount the image's boot filesystem."

# Go to work.
if [[ "$INSTALL" != "" ]]; then
	echo
	echo "Preparing for installation..."

	# Sets whether systemd checks the root filesystem at boot. The kernel usually boots
	# without an initrd now (of-bootnsh), and the initrd was what checked root at every
	# boot, so for ext2/3/4 systemd does it instead. btrfs needs no check.
	if [ "$FS" == "btrfs" ]; then
		CHECK=0
	else
		CHECK=1
	fi

	# If we're just copying from a .tgz.
	if [[ "$INSTALL" =~ ".tgz" ]]; then

		echo
		echo "DON'T FORGET! Check grub.cfg and fstab match your partition labels!"
		echo
		echo "Copying root contents from $INSTALL to image..."
		TARDIR=$(echo $INSTALL | sed 's/\.tgz$//g')
		tar zxf $INSTALL -C $MP $TARDIR/root --strip-components 2 || die "couldn't copy the root contents."
		sleep 1
		echo "Copying boot contents from $INSTALL to image..."
		tar zxf $INSTALL -C $MP/boot $TARDIR/boot --strip-components 2 || die "couldn't copy the boot contents."
		mmc_cfg

	# If we're copying from genuine directory tree.
	elif [ -d "$INSTALL" ]; then

		BOOTLABEL=$(ls -1 $INSTALL | grep boot)
		ROOTLABEL=$(ls -1 $INSTALL | grep root)

		echo
		echo "DON'T FORGET! Check grub.cfg and fstab match your partition labels!"
		echo
		echo "Copying root contents from $INSTALL directory to image..."
		cp -a $INSTALL/$ROOTLABEL/. $MP || die "couldn't copy the root contents."
		sleep 1
		echo "Copying boot contents from $INSTALL directory to image..."
		cp -a $INSTALL/$BOOTLABEL/. $MP/boot || die "couldn't copy the boot contents."
		mmc_cfg

	# Otherwise, fetch, duplicate, modify and chrootitoot.
	else

		CODENAME=$(echo "${INSTALL[@]^}")

		# Fetch.
		if [ ! -d $DBSLOC ]; then
			echo "Fetching ${DISTNAME^} $CODENAME with debootstrap from $DBSERVER..."
			echo
			mkdir $DBSLOC
			# A failed fetch mustn't stay as the cache the next build takes as complete.
			debootstrap --arch i386 --exclude=tasksel,tasksel-data $INSTALL $DBSLOC $DBSERVER ||
				{ rm -rf $DBSLOC; die "debootstrap couldn't fetch ${DISTNAME^} $CODENAME."; }
			sync
			sync
			sleep 2
		else
			echo
			echo "Debootstrap cache '$DBSLOC' already exists. Moving on..."
		fi

		# Duplicate.
		if [ ! -d $BLDLOC ]; then
			echo
			echo "Duplicating '$DBSLOC' into build directory '$BLDLOC'..."
			cp -R $DBSLOC $BLDLOC

			# Modify.
			if [[ "$OVERLAY" != "" ]]; then

				echo
				echo "Preparing system for OpenFrame..."
				echo
				echo -n "Sanitising overlay..."
				find $OVERLAY -type f -name .DS_Store -delete
				echo " done."
				echo
				sync
				sleep 1
				echo "Copying '$OVERLAY'..."
				echo
				cp -Rv $OVERLAY/* $BLDLOC

				# Replace the placeholders in grub.cfg
				if [[ "$OFVARIANT" == "of1" ]] || [[ "$OFVARIANT" == "of2" ]]; then
					sed -i "s/KERNVERLABEL/$KERNVER (Internal)/" $BLDLOC/boot/grub.cfg
				else
					sed -i "s/KERNVERLABEL/$KERNVER/" $BLDLOC/boot/grub.cfg
				fi

				sed -i "s/ROOTDEV/LABEL=$RNAME/" $BLDLOC/boot/grub.cfg
				sed -i "s/DISTNAME/${DISTNAME^}/" $BLDLOC/boot/grub.cfg
				sed -i "s/CODENAME/${CODENAME^}/" $BLDLOC/boot/grub.cfg
				sed -i "s/KERNVER/$KERNVER/" $BLDLOC/boot/grub.cfg
				sed -i "s/ROOTFST/$FS/" $BLDLOC/boot/grub.cfg

				# boot.nsh is written once the kernel is in (below).

				# Replace the placeholders in fstab
				sed -i "s/BOOTDEV/LABEL=$BNAME/" $BLDLOC/etc/fstab
				sed -i "s/ROOTDEV/LABEL=$RNAME/" $BLDLOC/etc/fstab
				sed -i "s/FS/$FS/" $BLDLOC/etc/fstab
				sed -i "s/MOUNTOPTS/$MOUNTOPTS/" $BLDLOC/etc/fstab
				sed -i "s/CHECK/$CHECK/" $BLDLOC/etc/fstab

				# Replace the placeholders used for apt
				sed -i "s=DBSERVER=$DBSERVER=" $BLDLOC/etc/apt/sources.list
				sed -i "s/CODENAME/$INSTALL/" $BLDLOC/etc/apt/sources.list

				mount --bind /dev $BLDLOC/dev
				mount --bind /dev/pts $BLDLOC/dev/pts
				mount --bind /proc $BLDLOC/proc
				mount --bind /sys $BLDLOC/sys
				mount --bind /tmp $BLDLOC/tmp
				[[ "$KERNELDIR" != "" ]] && mount --bind $KERNELDIR $BLDLOC/mnt

				# Chrootitoot.
				sync
				sync

				if [ -d $BLDLOC/run_on_build ]; then
					for f in $(ls $BLDLOC/run_on_build); do
						echo
						echo "Running $f in chroot..."
						chmod +x $BLDLOC/run_on_build/$f
						chroot $BLDLOC /run_on_build/$f || die "$f failed in chroot."
						sync
					done
					rm -rf $BLDLOC/run_on_build
				fi

				# The kernel starts directly from the firmware's shell, with the initrd,
				# which finds root by label until first boot (of-identifier) gives the
				# partitions their own identifiers. The image's own of-bootnsh, whichever
				# openframe-scripts the chroot got, and 'stub' in case that was GRUB mode.
				bash $BLDLOC/usr/local/sbin/of-bootnsh stub $BLDLOC/boot >/dev/null || die "of-bootnsh couldn't write boot.nsh."

				sync
				sync
				sleep 5
				sync
				sync

				unbind_chroot

				# Only the image's own /tmp, never the host's (if it wouldn't let go).
				mountpoint -q $BLDLOC/tmp || rm -rf $BLDLOC/tmp/*
				rm -rf $BLDLOC/var/log/*
				rm -rf $BLDLOC/var/tmp/*

			fi

		else

			echo
			echo "Build location $BLDLOC already exists. We'll just copy the thing..."
			echo
			echo "DON'T FORGET! Check grub.cfg and fstab match your partition labels!"

		fi

		echo
		echo "Removing large unnecessary firmwares..."
		rm -rf \
			$BLDLOC/lib/firmware/liquidio \
			$BLDLOC/lib/firmware/netronome \
			$BLDLOC/lib/firmware/amdgpu \
			$BLDLOC/lib/firmware/radeon \
			$BLDLOC/lib/firmware/qed \
			$BLDLOC/lib/firmware/ti-connectivity \
			$BLDLOC/lib/firmware/cxgb4 \
			$BLDLOC/lib/firmware/mellanox \
			$BLDLOC/lib/firmware/dpaa2 \
			$BLDLOC/lib/firmware/mrvl \
			$BLDLOC/lib/firmware/intel/i915 \
			$BLDLOC/lib/firmware/iwlwifi-* \
			2>/dev/null
		echo
		echo -n "Moving prepared ${DISTNAME^} ${CODENAME^} from '$BLDLOC' to image file on '$MP'..."
		unbind_chroot
		if ! bldloc_unmounted; then
			echo
			echo "Error: something is still mounted under $BLDLOC (see findmnt): not copying or removing it."
			exit 1
		fi
		# (24: some files vanished while copying, which can only be ones nothing needs.)
		rsync -a $BLDLOC/ $MP || [ $? -eq 24 ] || die "couldn't copy the build into the image."
		sleep 2
		sync
		sync
		rm -rf $BLDLOC
		echo " done."

		# A build directory that already existed was set up for whichever image it was
		# made for, so boot.nsh is written for this one: from a stick the kernel starts
		# directly; on the internal memory as mmc_cfg explains.
		if [[ "$OFVARIANT" == "of1" ]] || [[ "$OFVARIANT" == "of2" ]]; then
			bash $MP/usr/local/sbin/of-bootnsh stub mmc $MP/boot >/dev/null || die "of-bootnsh couldn't write boot.nsh."
		else
			bash $MP/usr/local/sbin/of-bootnsh stub $MP/boot >/dev/null || die "of-bootnsh couldn't write boot.nsh."
		fi
		echo
		sleep 2
		sync
		image_check

	fi

	echo
	df -h | grep $MP
	echo

fi

INSPECT=n
echo
echo
echo -n "Would you like to hold the image open? (y/N): "
read -t 10 INSPECT
if [[ "$INSPECT" == "y" ]] || [[ "$INSPECT" == "Y" ]]; then
	read -n 1 -p "The image will be held open at $MP until you press a key... "
else
	echo "n"
fi
echo
echo

cleanup $MP
