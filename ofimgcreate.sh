#!/bin/bash

# ofimgcreate v1.34 (3rd December 2014)
#  Used to prepare an OpenFrame image file from a .tgz or using debootstrap.

#set -x

#DBSERVER="http://archive.ubuntu.com/ubuntu/"
DBSERVER="http://ubuntu.datahop.net/ubuntu/"

countdown() {
  local i
  echo -n $1
  sleep 1
  for ((i=$1-1; i>=1; i--)); do
    printf "\b%d" $i
    sleep 1
  done
  printf "\b\b\b\bnow..."
}

if [[ "$#" < 4 ]]; then
  echo "Usage: $0 <name> <filesystem> <totalMB> <bootMB> <swapMB> [ <tgz|dbsver> [overlay] [kerneldir] ]"
  echo
  echo "Required:"
  echo
  echo "name:            System name. Will be used for filename and partition prefix."
  echo "filesystem:      Choose from ext2, ext4 or btrfs."
  echo "totalMB:         The total size of the image file; specify 'of1' or 'of2' for respective internal MMC."
  echo "bootMB:          The size of the FAT16 boot volume (32MB minimum)."
  echo "swapMB:          The size of the swap partition. Enter 0 for no swap."
  echo
  echo "Optional:"
  echo
  echo "tgz|dbsver:      Extract a .tgz onto the image. Must contain 'boot' and 'root' directories."
  echo "                   OR"
  echo "                 Name of release to be installed with debootstrap (eg. lucid)."
  echo "overlay:         Directory containing overlay files to be copied (debootstrap use only)."
  echo "kerneldir:       Directory containing linux-image and linux-header packages (debootstrap use only)."
  echo
  exit 0
fi

if [ "$USER" != "root" ]; then
	echo "You need to run this with superuser privileges."
	exit 0
fi

DBPRESENT=`which debootstrap`
if [ "$DBPRESENT" == "" ]; then
  echo "You need to install debootstrap for this to work."
  exit 0
fi

NAME="$1"
FS="$2"
if [ "$FS" == "ext3" ]; then
	echo "We don't support ext3. Setting to ext4 instead."
	FS="ext4"
fi
if [ "$FS" == "btrfs" ]; then
  echo "Our btrfs is currently broken. Setting to ext2 instead."
  FS="ext2"
fi

TSIZE="$3"
OFVARIANT="$3"

# If 'of1' or 'of2' is given for size, create an image that matches the OpenFrame 1 or 2 internal storage.
# We fake 1028MB or 2055MB for the calculations, but dd will create an image file of the correct size later.
if [[ "$TSIZE" == "of1" ]]; then
	TSIZE="1028"
	MMCINT="1028128768"
elif [[ "$TSIZE" == "of2" ]]; then
  TSIZE="2055"
  MMCINT="2055208960"
else
	MMCINT="0"
fi

BSIZE="$4"
SSIZE="$5"
INSTALL="$6"
OVERLAY="$7"
KERNELDIR="$8"
OFF=0
RSIZE=$(($TSIZE-$BSIZE-$SSIZE))

if [[ "$INSTALL" != "" ]] && [[ ! "$INSTALL" =~ "tgz" ]] && [[ "$#" < 8 ]] && [ ! -d "$INSTALL" ]; then
  echo "Overlay and kernel files are required for a working system."
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
  KERNVER=`ls $KERNELDIR | grep linux-image | awk -F\- '{print $3}' | awk -F\_ '{print $1}'`
  FILENAME="$NAME-$FS-$TSIZE-$BSIZE-$INSTALL-$KERNVER.img"
else
  TGZNAME=`echo $INSTALL | awk -F\. {'print $1'}`
  FILENAME="$TGZNAME"_"$OFVARIANT".img
fi

FILEWARN=`ls | grep -c $FILENAME`
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
  echo "Creating image from existing directory structure..."
else
  echo "Creating image from debootstrap..."
fi
echo

echo "Image filename will be: $FILENAME"
echo
sleep 1

# Set up the debootstrap cache and build directory names.
DBSLOC=$6"_dbscache"
BLDLOC=$6"-"$NAME"-openframe-"$KERNVER

# Juggle partition numbers if we've got no swap area.
if [[ "$SSIZE" == "0" ]]; then
  RPARTNUM=2
  RLOOPNUM=1
else
  RPARTNUM=3
  RLOOPNUM=2
fi

# Impose name character limit. Too long and the label will be truncated.
if [[ ${#NAME} > 5 ]]; then
  echo "Name prefix must be 5 characters or fewer."
  exit 0
else
  RNAME="$NAME"-root
  BNAME="$NAME"-boot
  SNAME="$NAME"-swap
  echo "Partitions will be:"
  echo "  boot: $BNAME"
  echo "        ("$BSIZE"MB)"
  [[ "$SSIZE" > "0" ]] && echo "  swap: $SNAME"
  [[ "$SSIZE" > "0" ]] && echo "  ("$SSIZE"MB)"
  echo "  root: $RNAME"
  echo "        ("$RSIZE"MB)"
  echo
  sleep 2
fi


partitions_create()
{
  BOOTEND=$(($OFF+$BSIZE))
  if [[ "$SSIZE" > "0" ]]; then
    SWAPEND=$(($OFF+$BSIZE+$SSIZE))
    parted -s "$FILENAME" -- \
      mklabel msdos \
      mkpart primary fat16 $OFF $BOOTEND \
      set 1 boot on \
      mkpart primary "$NAME"swap $BOOTEND $SWAPEND \
      mkpart primary $SWAPEND -1
  else
    parted -s "$FILENAME" -- \
      mklabel msdos \
      mkpart primary fat16 $OFF $(($OFF+$BSIZE)) \
      set 1 boot on \
      mkpart primary $BOOTEND -1
  fi
  sync
  sleep 2
}

get_part_byte_offset()
{
  PART=$1
  OFF=$(($2+1))
  parted -m "$FILENAME" unit b print | grep "^$PART" | cut -d: -f $OFF | sed -e "s/\([0-9]\+\)B/\1/g"
}

# loop#, partition
loop_create()
{
  OFFSET=$(get_part_byte_offset $2 1)
  SIZE=$(get_part_byte_offset $2 3)
  losetup /dev/loop$1 --offset $OFFSET --sizelimit $SIZE "$FILENAME"
}

loop_delete()
{
  losetup -d /dev/loop$1
}

loop_mount()
{
  loop_create 0 1
  loop_create 1 2
  [[ "$SSIZE" > "0" ]] && loop_create 2 3
}

filesystems_create()
{
  mkfs.vfat -F 16 -n "$BNAME" /dev/loop0

  if [[ "$SSIZE" > "0" ]]; then
    mkswap -L "$SNAME" /dev/loop1
    ROOTLOOP="/dev/loop2"
  else
    ROOTLOOP="/dev/loop1"
  fi

  case $1 in
    btrfs)
      echo "Btrfs configuration."
      MKFS="mkfs.btrfs -m single"
      TUNEFS=""
      FSCK=""
    ;;
    ext2)
      echo "ext2 configuration."
      MKFS="mkfs.$FS"
      TUNEFS="tune2fs -i 0 $ROOTLOOP"
      FSCK="e2fsck -f $ROOTLOOP"
    ;;
    ext4)
      echo "ext4 (without journal) configuration."
      MKFS="mkfs.$FS -O ^has_journal"
      TUNEFS="tune2fs -i 0 $ROOTLOOP"
      FSCK="e2fsck -f $ROOTLOOP"
    ;;
  esac

  $MKFS -L "$RNAME" $ROOTLOOP
  $TUNEFS
  sync
  sleep 2
  $FSCK
  sync
  sleep 2
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
  loop_delete 2 2>/dev/null
  echo
  echo "Creation of $FILENAME is complete."
  echo
  exit
}


## Let's get underway...
trap cleanup INT

# Make the image file.
echo "Creating "$TSIZE"MB image file..."
if [ "$MMCINT" != "0" ]; then
	dd if=/dev/zero of="$FILENAME" bs=$MMCINT count=1
else
	dd if=/dev/zero of="$FILENAME" bs=1MB count=$TSIZE
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
loop_mount
filesystems_create $FS

# Create mount points.
MP=/tmp/img$RANDOM
mkdir $MP
echo
echo "Mounting image file as $MP..."

case $FS in
  btrfs)
    MOUNTOPTS="compress,noatime,noacl"
  ;;
  ext2)
    MOUNTOPTS="errors=remount-ro,noatime,noacl"
  ;;
  ext4)
    MOUNTOPTS="errors=remount-ro,noatime,noacl"
  ;;
esac

# Mount the image file.
mount -t $FS -o $MOUNTOPTS /dev/loop$RLOOPNUM $MP
mkdir $MP/boot
umount /dev/loop0 2>/dev/null
sleep 4
mount -t vfat /dev/loop0 $MP/boot


# Go to work.
if [[ "$INSTALL" != "" ]]; then
  echo
  echo "Preparing for installation..."

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
    TARDIR=`echo $INSTALL | sed 's/\.tgz$//g'`
    tar zxf $INSTALL -C $MP $TARDIR/root --strip-components 2
    sleep 1
    echo "Copying boot contents from $INSTALL to image..."
    tar zxf $INSTALL -C $MP/boot $TARDIR/boot --strip-components 2

    # Set some system defaults for first boot if of1 or of2 specified.
    if [[ "$OFVARIANT" == "of1" ]]; then
      echo
      echo -n "Configuring OpenFrame 1 first boot defaults..."

      # Ensure that the audio firmware patch is applied.
      [ ! -f $MP/etc/modprobe.d/of1-stac9202.conf ] && echo "options snd-hda-intel position_fix=1 bdl_pos_adj=64 patch=of1-stac9202.patch" > $MP/etc/modprobe.d/of1-stac9202.conf

      # We're not bothered about restricting the b43 driver.
      [ -f $MP/etc/modprobe.d/blacklist-of2-b43.conf ] && rm $MP/etc/modprobe.d/blacklist-of2-b43.conf

      echo " done."
      echo
    elif [[ "$OFVARIANT" == "of2" ]]; then
      echo
      echo -n "Configuring OpenFrame 2 first boot defaults..."

      # Ensure that the OF1 audio firmware patch is removed.
      [ -f $MP/etc/modprobe.d/of1-stac9202.conf ] && rm $MP/etc/modprobe.d/of1-stac9202.conf

      # Ensure that the b43 wireless driver is disabled (we use brcmsmac).
      [ ! -f $MP/etc/modprobe.d/blacklist-of2-b43.conf ] && echo "blacklist b43" > $MP/etc/modprobe.d/blacklist-of2-b43.conf

      echo " done."
      echo
    fi

  # If we're copying from genuine directory tree.
  elif [ -d "$INSTALL" ]; then
    
    echo
    echo "DON'T FORGET! Check grub.cfg and fstab match your partition labels!"
    echo
    echo "Copying root contents from $INSTALL directory to image..."
    cp -a $INSTALL/root/. $MP
    sleep 1
    echo "Copying boot contents from $INSTALL directory to image..."
    cp -a $INSTALL/boot/. $MP/boot

  # Otherwise, fetch, duplicate, modify and chrootitoot.
  else

    UBUNTUVER=`echo "${INSTALL[@]^}"`

	# Fetch.
	if [ ! -d $DBSLOC ]; then
		echo "Fetching Ubuntu $UBUNTUVER with debootstrap from $DBSERVER..."
		echo
		mkdir $DBSLOC
		debootstrap --arch i386 $INSTALL $DBSLOC $DBSERVER
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
	    if [[ "$OVERLAY" != "" ]] && [[ "$KERNELDIR" != "" ]]; then

	      echo
	      echo "Preparing system for OpenFrame..."

		  echo
      echo "Copying '$OVERLAY'..."
      cp -R $OVERLAY/* $BLDLOC

      # Replace the placeholders in grub.cfg
      sed -i "s/UBUNTUVER/$UBUNTUVER/" $BLDLOC/boot/grub.cfg

      if [[ "$OFVARIANT" == "of1" ]] || [[ "$OFVARIANT" == "of2" ]]; then
        sed -i "s/KERNVERLABEL/$KERNVER (Internal)/" $BLDLOC/boot/grub.cfg
        sed -i "s/LABEL=RNAME/\/dev\/mmcblk0p2/" $BLDLOC/boot/grub.cfg
      else
        sed -i "s/KERNVERLABEL/$KERNVER/" $BLDLOC/boot/grub.cfg
        sed -i "s/RNAME/$RNAME/" $BLDLOC/boot/grub.cfg
      fi

      sed -i "s/KERNVER/$KERNVER/" $BLDLOC/boot/grub.cfg

      # Replace the placeholders used for apt
      sed -i "s/UBUNTUVER/$INSTALL/" $BLDLOC/etc/apt/sources.list
      sed -i "s/UBUNTUVER/$INSTALL/" $BLDLOC/etc/apt/sources.list.d/disabled/openframe-jools.list
      sed -i "s/UBUNTUVER/$INSTALL/" $BLDLOC/etc/apt/sources.list.d/disabled/openframe-emgd.list

      # Replace the placeholders in fstab
 
      sed -i "s/FS/$FS/" $BLDLOC/etc/fstab
      sed -i "s/MOUNTOPTS/$MOUNTOPTS/" $BLDLOC/etc/fstab
      sed -i "s/CHECK/$CHECK/" $BLDLOC/etc/fstab

      if [[ "$OFVARIANT" == "of1" ]] || [[ "$OFVARIANT" == "of2" ]]; then
        sed -i "s/LABEL=RNAME/\/dev\/mmcblk0p2/" $BLDLOC/etc/fstab
        sed -i "s/LABEL=BNAME/\/dev\/mmcblk0p1/" $BLDLOC/etc/fstab
      else
        sed -i "s/RNAME/$RNAME/" $BLDLOC/etc/fstab
        sed -i "s/BNAME/$BNAME/" $BLDLOC/etc/fstab
      fi

      if [[ "$SSIZE" > "0" ]]; then
        sed -i "s/SNAME/$SNAME/" $BLDLOC/etc/fstab
      else
        cat $BLDLOC/etc/fstab | grep -v swap > $BLDLOC/etc/fstab.noswap
        mv $BLDLOC/etc/fstab.noswap $BLDLOC/etc/fstab
      fi

      #if [ "$FS" != "btrfs" ]; then
      #  rm $BLDLOC/etc/cron.d/btrfs_balance
      #  rm $BLDLOC/usr/local/bin/balancecheck
      #fi

      # Make sure that the console font isn't changed. I'm not keen on that.
      sed -i "s/FONTFACE=\"Fixed\"/FONTFACE=\"VGA\"/" $BLDLOC/etc/default/console-setup

      mount --bind /dev $BLDLOC/dev
      mount --bind /dev/pts $BLDLOC/dev/pts
      mount --bind /proc $BLDLOC/proc
      mount --bind /sys $BLDLOC/sys
      mount --bind /tmp $BLDLOC/tmp
      mount --bind $KERNELDIR $BLDLOC/mnt

      # Chrootitoot.
      sync
      sync
      if [ -f $BLDLOC/ofprep.sh ]; then
        echo
        echo "Running ofprep.sh in chroot..."
        chroot $BLDLOC /ofprep.sh
        sleep 2
        rm $BLDLOC/ofprep.sh
      fi

      sync
      sync
      sleep 5
      sync
      sync

		  umount $BLDLOC/mnt
		  umount $BLDLOC/tmp
		  umount $BLDLOC/sys
		  umount -l $BLDLOC/proc
		  umount $BLDLOC/dev/pts
		  umount -l $BLDLOC/dev

		  rm -rf $BLDLOC/tmp/*
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
	echo -n "Moving prepared Ubuntu $UBUNTUVER from '$BLDLOC' to image file on '$MP'..."
	rsync -a $BLDLOC/ $MP
  sleep 2
  sync
  sync
  rm -rf $BLDLOC
	echo " done."
	echo
  sleep 2
  
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

