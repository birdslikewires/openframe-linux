#!/bin/bash

# ofimgcreate v1.46 (6th August 2019)
#  Used to prepare an OpenFrame image file from a .tgz or using debootstrap.

#set -x

DBSERVER="http://gb.archive.ubuntu.com/ubuntu/"

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

if [[ "$#" < 6 ]]; then
  echo "Usage: $0 <name> <filesystem> <initramfs> <totalMB> <bootMB> <swapMB> <source> [overlay] [kerneldir]"
  echo
  echo "  name:            System name. Will be used for filename and partition prefix."
  echo "  filesystem:      Choose from ext2, ext4 or btrfs."
  echo "  initramfs        Enter '1' to use an initrd, or '0' to boot without it."
  echo "  totalMB:         The total size of the image file; specify 'of1' or 'of2' for respective internal MMC."
  echo "  bootMB:          The size of the FAT16 boot volume (8 MB minimum with no initrd, otherwise 32 MB minimum)."
  echo "  swapMB:          The size of the swap partition. Enter 0 for no swap."
  echo "  source:          Source of operating system, MUST BE QUOTED. You have three options here:"
  echo "                      1) Give an official distro name and code name, eg. "ubuntu bionic"."
  echo "                      2) Point to a local path containing boot and root structures."
  echo "                      3) Point to a local .tgz file containing boot and root structures."
  echo
  echo "  overlay:         Location of overlay files to be copied (required when using distro name and code name as source)."
  echo "  kerneldir:       Location of linux-image and linux-header packages (required when using distro name and code name as source)."
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

NAME="${1^^}"
FS="$2"
if [ "$FS" == "ext3" ]; then
	echo "We don't support ext3. Setting to ext4 instead."
	FS="ext4"
fi
if [ "$FS" == "btrfs" ]; then
  echo "Our btrfs methods are broken. Setting to ext2 instead."
  FS="ext2"
fi

USEINITRD="$3"
TSIZE="$4"
OFVARIANT="$4"
BSIZE="$5"

## If 'of1' or 'of2' is given for size, create an image that exactly matches the OpenFrame 1 or 2 internal storage.
##  On the OpenFrame1 we override the boot partition size to 32MB. This is the minimum size that still allows update-initramfs to work.
if [[ "$TSIZE" == "of1" ]]; then

  BYTESSIZE="1028128768"
  TSIZE="1028"

  if [ $USEINITRD -gt 0 ] && [ $BSIZE -eq 0 ]; then
    BSIZE="32"
    echo
    echo "OpenFrame 1 boot size set to minimum for initramfs ($BSIZE MB)."
  elif [ $USEINITRD -eq 0 ] && [ $BSIZE -eq 0 ]; then
    BSIZE="8"
    echo
    echo "OpenFrame 1 boot size set to minimum ($BSIZE MB)."
  fi

elif [[ "$TSIZE" == "of2" ]]; then

	BYTESSIZE="2055208960"
	TSIZE="2055"

elif [[ "$TSIZE" == "uni" ]]; then

  BYTESSIZE="1028128768"
  TSIZE="1028"

else

	BYTESSIZE="0"

	if [ $USEINITRD -gt 0 ] && [ $BSIZE -lt 32 ]; then
		BSIZE="32"
		echo
		echo "Specified boot size too small; overridden to $BSIZE MB to accommodate initramfs."
	fi

	if [ $USEINITRD -eq 0 ] && [ $BSIZE -lt 8 ]; then
		BSIZE="8"
		echo
		echo "Specified boot size too small; overridden to $BSIZE MB."
	fi

fi

SSIZE="$6"
INSTALL="$7"
DISTNAME=$(echo "$INSTALL" | awk -F\  {'print $1'})
CODENAME=$(echo "$INSTALL" | awk -F\  {'print $2'})
OVERLAY="$8"
KERNELDIR="$9"
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
  FILENAME="${NAME,,}-$FS-$TSIZE-$BSIZE-$INSTALL-$KERNVER.img"
else
  if [[ "$INSTALL" =~ "tgz" ]]; then
    CLONENAME=`echo $INSTALL | awk -F\. {'print $1'}`
  else
    CLONENAME="${NAME,,}"
  fi
  FILENAME="$CLONENAME"_"$OFVARIANT".img
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
  RNAME="$NAME"-ROOT
  BNAME="$NAME"-BOOT
  SNAME="$NAME"-SWAP
  echo "Partitions will be:"
  echo "  boot: $BNAME"
  echo "        ("$BSIZE"MB)"
  [[ "$SSIZE" > "0" ]] && echo "  swap: $SNAME"
  [[ "$SSIZE" > "0" ]] && echo "  ("$SSIZE"MB)"
  echo "  root: $RNAME"
  echo "        ("$RSIZE"MB)"
  echo
  sleep 4
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
  # Create our own loop devices so we're not in competition with anyone.
  if [ ! -e /dev/of-loop0 ]; then
    /bin/mknod /dev/of-loop0 b 7 200
    /bin/mknod /dev/of-loop1 b 7 201
    /bin/mknod /dev/of-loop2 b 7 202
  fi
  OFFSET=$(get_part_byte_offset $2 1)
  SIZE=$(get_part_byte_offset $2 3)
  /sbin/losetup /dev/of-loop$1 --offset $OFFSET --sizelimit $SIZE "$FILENAME"
}

loop_delete()
{
  /sbin/losetup -d /dev/of-loop$1
}

loop_mount()
{
  loop_create 0 1
  loop_create 1 2
  [[ "$SSIZE" > "0" ]] && loop_create 2 3
}

filesystems_create()
{
  mkfs.vfat -F 16 -n "$BNAME" /dev/of-loop0

  if [[ "$SSIZE" > "0" ]]; then
    mkswap -L "$SNAME" /dev/of-loop1
    ROOTLOOP="/dev/of-loop2"
  else
    ROOTLOOP="/dev/of-loop1"
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

mmc_cfg() {
  if [[ "$OFVARIANT" == "of1" ]] || [[ "$OFVARIANT" == "of2" ]]; then
    echo
    echo -n "Configuring internal memory GRUB and FSTAB settings..."

    # Point /etc/fstab to the internal memory.
    EXISTINGROOTLOCATION=`cat $MP/etc/fstab | grep $FS | awk -F\  {'print $1'}`
    sed -i "s,$EXISTINGROOTLOCATION,/dev/mmcblk0p2," $MP/etc/fstab
    EXISTINGBOOTLOCATION=`cat $MP/etc/fstab | grep "/boot" | awk -F\  {'print $1'}`
    sed -i "s,$EXISTINGBOOTLOCATION,/dev/mmcblk0p1," $MP/etc/fstab

    # Point /boot/grub.cfg to the internal memory.
    sed -i "s,$EXISTINGROOTLOCATION,/dev/mmcblk0p2," $MP/boot/grub.cfg 

    echo " done."
  fi
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
if [ "$BYTESSIZE" != "0" ]; then
	dd if=/dev/zero of="$FILENAME" bs=$BYTESSIZE count=1
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
mount -t $FS -o $MOUNTOPTS /dev/of-loop$RLOOPNUM $MP
mkdir $MP/boot
umount /dev/of-loop0 2>/dev/null
sleep 4
mount -t vfat /dev/of-loop0 $MP/boot


# Go to work.
if [[ "$INSTALL" != "" ]]; then
  echo
  echo "Preparing for installation..."

  # Sets whether we check for errors on boot.
  if [ "$FS" == "btrfs" ]; then
    CHECK=0
  else
    ## Disabled checking - this was proving more trouble than it was worth.
    #CHECK=1
    CHECK=0
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
    mmc_cfg

  # If we're copying from genuine directory tree.
  elif [ -d "$INSTALL" ]; then
    
    BOOTLABEL=`ls -1 $INSTALL | grep boot`
    ROOTLABEL=`ls -1 $INSTALL | grep root`

    echo
    echo "DON'T FORGET! Check grub.cfg and fstab match your partition labels!"
    echo
    echo "Copying root contents from $INSTALL directory to image..."
    cp -a $INSTALL/$ROOTLABEL/. $MP
    sleep 1
    echo "Copying boot contents from $INSTALL directory to image..."
    cp -a $INSTALL/$BOOTLABEL/. $MP/boot
    mmc_cfg

  # Otherwise, fetch, duplicate, modify and chrootitoot.
  else

    CODENAME=`echo "${INSTALL[@]^}"`

	# Fetch.
	if [ ! -d $DBSLOC ]; then
		echo "Fetching ${DISTNAME^} $CODENAME with debootstrap from $DBSERVER..."
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
      echo -n "Sanitising overlay..."
      find $OVERLAY -type f -name .DS_Store -delete
      echo " done."
      sync
      sleep 1
      echo "Copying '$OVERLAY'..."
      cp -Rv $OVERLAY/* $BLDLOC

      # Replace the placeholders in grub.cfg
      if [[ "$OFVARIANT" == "of1" ]] || [[ "$OFVARIANT" == "of2" ]]; then
        sed -i "s/KERNVERLABEL/$KERNVER (Internal)/" $BLDLOC/boot/grub.cfg
      else
        sed -i "s/KERNVERLABEL/$KERNVER/" $BLDLOC/boot/grub.cfg
      fi

      sed -i "s/ROOTDEV/LABEL=$RNAME/" $BLDLOC/boot/grub.cfg
      sed -i "s/CODENAME/$CODENAME/" $BLDLOC/boot/grub.cfg
      sed -i "s/KERNVER/$KERNVER/" $BLDLOC/boot/grub.cfg
      sed -i "s/ROOTFST/$FS/" $BLDLOC/boot/grub.cfg

      if [ $USEINITRD -ne 1 ]; then
        cat $BLDLOC/boot/grub.cfg | grep -v initrd > $BLDLOC/boot/grub.cfg.noinitrd
        mv $BLDLOC/boot/grub.cfg.noinitrd $BLDLOC/boot/grub.cfg
      fi

      # Replace the placeholders in fstab
      sed -i "s/BOOTDEV/LABEL=$BNAME/" $BLDLOC/etc/fstab
      sed -i "s/ROOTDEV/LABEL=$RNAME/" $BLDLOC/etc/fstab
      sed -i "s/FS/$FS/" $BLDLOC/etc/fstab
      sed -i "s/MOUNTOPTS/$MOUNTOPTS/" $BLDLOC/etc/fstab
      sed -i "s/CHECK/$CHECK/" $BLDLOC/etc/fstab

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

      # Replace the placeholders used for apt
      sed -i "s=DBSERVER=$DBSERVER=" $BLDLOC/etc/apt/sources.list
      sed -i "s/CODENAME/$INSTALL/" $BLDLOC/etc/apt/sources.list

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

      if [ -d $BLDLOC/run_on_build ]; then
        for f in `ls $BLDLOC/run_on_build`; do
          echo
          echo "Running $f in chroot..."
          chmod +x $BLDLOC/run_on_build/$f
          chroot $BLDLOC /run_on_build/$f
          sync
        done
        rm -rf $BLDLOC/run_on_build
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
  echo "Removing large unnecessary firmwares..."
  rm -rf $BLDLOC/lib/firmware/liquidio $BLDLOC/lib/firmware/netronome $BLDLOC/lib/firmware/amdgpu $BLDLOC/lib/firmware/radeon $BLDLOC/lib/firmware/qed $BLDLOC/lib/firmware/ti-connectivity $BLDLOC/lib/firmware/cxgb4 2>/dev/null
	echo
	echo -n "Moving prepared ${DISTNAME^} ${CODENAME^} from '$BLDLOC' to image file on '$MP'..."
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

