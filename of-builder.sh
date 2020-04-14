#!/bin/bash

## of-builder.sh v1.15 (14th April 2020)
##  Builds kernels, modules and images.

if [ $# -lt 1 ]; then
	echo "Usage: $0 <kernelbranch> <distro> <codename> <url>"
	exit 1
fi

## Configurable Bits

OURKERNVER="op"
PATHTODOWNLOADAREA="/home/andy/Public/download_blw/openframe"
GITREPOURL="https://github.com/birdslikewires"
GITREPOKER="openframe-kernel"
GITREPOLIN="openframe-linux"
COREDIVIDER=1

## Everything Else

THISSCRIPTPATH="$(cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P)"
STARTTIME=`date +'%Y-%m-%d-%H%M'`
KBRANCH="$1"
KARCHIVES=`curl --silent https://www.kernel.org/index.html`
KDOWNLOAD=`echo "$KARCHIVES" | grep -m 1 "linux-$KBRANCH" | grep ".xz" | awk -F\" {'print $2'}`
GITKERNELUPDATED=0
GITLINUXOUPDATED=0

if [[ ! "$KDOWNLOAD" ]]; then
	echo "`date  +'%Y-%m-%d %H:%M:%S'`: Kernel branch $KBRANCH was not found as stable or longterm on the kernel.org homepage."
	exit 1
fi


# Check whether we've got the kernel repo available, otherwise kernel builds will obviously fail.
if [[ ! -d "$THISSCRIPTPATH/../$GITREPOKER" ]]; then
	echo "`date  +'%Y-%m-%d %H:%M:%S'`: You're going to need $GITREPOURL/$GITREPOKER as well. Cloning..."
	git clone "$GITREPOURL/$GITREPOKER" "$THISSCRIPTPATH/../$GITREPOKER"
else
	KPULL=$(git -C "$THISSCRIPTPATH/../$GITREPOKER" pull)
	if [[ "$KPULL" == "Already up to date." ]]; then
		echo "`date  +'%Y-%m-%d %H:%M:%S'`: Local copy of repository '$GITREPOKER' is up to date."
	else
		GITKERNELUPDATED=1
		echo "`date  +'%Y-%m-%d %H:%M:%S'`: Local copy of repository '$GITREPOKER' requires update..."
		echo
		echo "$KPULL"
		echo
	fi
fi

# Check whether I've been removed from my repo or not. Die if I have.
if [[ ! -d "$THISSCRIPTPATH/../$GITREPOLIN" ]]; then
	echo "`date  +'%Y-%m-%d %H:%M:%S'`: You seem to be running me outside of my repo. I'm not much use without the rest of $GITREPOURL/$GITREPOLIN."
	exit 1
else
	LPULL=$(git -C "$THISSCRIPTPATH/../$GITREPOKER" pull)
	if [[ "$LPULL" == "Already up to date." ]]; then
		echo "`date  +'%Y-%m-%d %H:%M:%S'`: Local copy of repository '$GITREPOLIN' is up to date."
	else
		GITLINUXOUPDATED=1
		echo "`date  +'%Y-%m-%d %H:%M:%S'`: Local copy of repository '$GITREPOLIN' requires update..."
		echo
		echo "$LPULL"
		echo
	fi
fi

KFILENAME=`echo "$KDOWNLOAD" | sed 's:.*/::'`
KLATESTMAJVER=`echo "$KFILENAME" | awk -F\- {'print $2'} | awk -F\. {'print $1'}`
KLATESTMIDVER=`echo "$KFILENAME" | awk -F\- {'print $2'} | awk -F\. {'print $2'}`
KLATESTMINVER=`echo "$KFILENAME" | awk -F\- {'print $2'} | awk -F\. {'print $3'}`
KOURNAME="$KLATESTMAJVER.$KLATESTMIDVER.$KLATESTMINVER$OURKERNVER"
KOURBUILD="linux-$KLATESTMAJVER.$KLATESTMIDVER.$KLATESTMINVER"
KDLPATH="$PATHTODOWNLOADAREA/kernel/$KLATESTMAJVER.$KLATESTMIDVER/$KOURNAME"
[ -d $KDLPATH ] && [ $GITKERNELUPDATED -eq 0 ] && KBUILDIT=0 || KBUILDIT=1

IDISTNAME="$2"
ICODENAME="$3"
IDOWNLURL="$4"
IDLPATH="$PATHTODOWNLOADAREA/images/${IDISTNAME,,}/${ICODENAME,,}/$KLATESTMAJVER.$KLATESTMIDVER/$KOURNAME"
[ -d $IDLPATH ] && [ $GITLINUXOUPDATED -eq 0 ] && IBUILDIT=0 || IBUILDIT=1

## Work To Do!

cleanup() {
	echo -n "`date  +'%Y-%m-%d %H:%M:%S'`: Cleaning up..."
	chown -R www-data:www-data $PATHTODOWNLOADAREA/images $PATHTODOWNLOADAREA/kernel $PATHTODOWNLOADAREA/logs
	chmod -R 774 $PATHTODOWNLOADAREA/images $PATHTODOWNLOADAREA/kernel $PATHTODOWNLOADAREA/logs
	rm -rf ./$KOURBUILD*
	rm -rf ./*.deb
	rm -rf ./*.img*
	rm -rf ./tmp
	echo " done."
}

if [[ "$KBUILDIT" == 0 ]]; then

	echo "`date  +'%Y-%m-%d %H:%M:%S'`: Kernel $KOURNAME has already been processed."

else

	if [ -d $KDLPATH ]; then
		echo -n "`date  +'%Y-%m-%d %H:%M:%S'`: Removing outdated $KOURNAME kernel..."
		rm -rf $KDLPATH
		echo " done."
	fi

	echo "`date  +'%Y-%m-%d %H:%M:%S'`: Building $KOURNAME kernel..."
	echo

	if [ ! -f "$KFILENAME" ]; then
		echo -n "`date  +'%Y-%m-%d %H:%M:%S'`: Downloading $KFILENAME..."
		wget --quiet "$KDOWNLOAD"
		echo " done."
	else
		echo "`date  +'%Y-%m-%d %H:%M:%S'`: Kernel archive $KFILENAME found."
	fi

	if [ ! -f "$KFILENAME" ]; then
		echo "`date  +'%Y-%m-%d %H:%M:%S'`: Download appears to have failed."
		exit 1
	fi

	if [ -d "$KOURBUILD" ]; then
		echo -n "`date  +'%Y-%m-%d %H:%M:%S'`: Removing previous build cruft..."
		rm -rf "$KOURBUILD"
		rm -rf *.deb
		rm -rf ./tmp/*
		echo " done."
	fi

	echo -n "`date  +'%Y-%m-%d %H:%M:%S'`: Decompressing $KFILENAME..."
	tar xJf $KFILENAME
	echo " done."

	echo "`date  +'%Y-%m-%d %H:%M:%S'`: Applying OpenFrame kernel patches..."
	for p in `ls $GITREPOKER/patches/$KLATESTMAJVER.$KLATESTMIDVER`; do
		patch -f -p1 -d "$KOURBUILD" < "$GITREPOKER/patches/$KLATESTMAJVER.$KLATESTMIDVER/$p"
	done
	echo

	# This checks through the exit codes so far and kills us if any have been greater than zero.
	RCS=${PIPESTATUS[*]}; RC=0; for i in ${RCS}; do RC=$(($i > $RC ? $i : $RC)); done
	if [[ $RC -gt 0 ]]; then
		echo -n "`date  +'%Y-%m-%d %H:%M:%S'`: Build failed, check the log."
		cleanup
		exit $RC
	fi

	echo -n "`date  +'%Y-%m-%d %H:%M:%S'`: Applying extraversion to makefile..."
	KMAKEFILE=`cat "$KOURBUILD/Makefile"`
	if [[ ! "$KMAKEFILE" =~ "EXTRAVERSION = $OURKERNVER" ]]; then
		sed -i "s/EXTRAVERSION =/EXTRAVERSION = $OURKERNVER/g" "$KOURBUILD/Makefile"
	fi
	echo " done."

## This is unfortunately no good because overriding the architecture with '-d' still results in the packages being created
## with the wrong filename, due to it believing a 64-bit build was in progress.
#	if [ $KLATESTMAJVER -eq 5 ]; then
#		echo -n "`date  +'%Y-%m-%d %H:%M:%S'`: Applying -d flag to dpkg-buildpackage to work around cross-compiling misidentification issue..."
#		sed -i "s/dpkg-buildpackage/dpkg-buildpackage -d/g" "$KOURBUILD/scripts/package/Makefile"
#		echo " done."
#	fi

	echo "`date  +'%Y-%m-%d %H:%M:%S'`: Updating config file with new defaults..."
	KCONFIGFILE=`ls $GITREPOKER/configs | grep "$KLATESTMAJVER.$KLATESTMIDVER"`
	cp "$GITREPOKER/configs/$KCONFIGFILE" "$KOURBUILD/.config"
	cd "$KOURBUILD"
	make olddefconfig

	echo
	echo "Go! Go! Go!"
	echo
	make -j$((`nproc`/$COREDIVIDER)) deb-pkg

	RCS=${PIPESTATUS[*]}; RC=0; for i in ${RCS}; do RC=$(($i > $RC ? $i : $RC)); done
	if [[ $RC -gt 0 ]]; then
		echo
		echo "`date  +'%Y-%m-%d %H:%M:%S'`: Build failed, check the log."
		cd ..
		cleanup
		exit $RC
	fi

	echo
	echo "`date  +'%Y-%m-%d %H:%M:%S'`: Kernel build succeeded!"
	echo

	mkdir -p $KDLPATH
	cd ..
	echo -n "`date  +'%Y-%m-%d %H:%M:%S'`: Moving kernel $KOURNAME packages..."
	mv *.deb $KDLPATH
	echo " done."
	echo -n "`date  +'%Y-%m-%d %H:%M:%S'`: Copying kernel $KOURNAME config file..."
	cp "$KOURBUILD/.config" "$KDLPATH/$KOURNAME.config"
	echo " done."
	echo -n "`date  +'%Y-%m-%d %H:%M:%S'`: Copying kernel $KOURNAME patches..."
	cp -R "$GITREPOKER/patches/$KLATESTMAJVER.$KLATESTMIDVER" "$KDLPATH/patches"
	echo " done."
	echo
	cleanup
	echo
	echo "`date  +'%Y-%m-%d %H:%M:%S'`: Kernel compiled, packages ready."
	echo
	echo

fi

if [ -f $KDLPATH/modules-$KOURNAME.tgz ]; then

	echo "`date  +'%Y-%m-%d %H:%M:%S'`: Modules for kernel $KOURNAME have already been processed."

else

	echo "`date  +'%Y-%m-%d %H:%M:%S'`: Building $KOURNAME kernel companion modules..."

	[ ! -d /lib/modules/$KOURNAME ] && dpkg -i $KDLPATH/linux-headers*

	if [[ "$KLATESTMAJVER" -lt 4 ]]; then

		## RTL8821CU Wireless Support
		[ -d rtl8821cu_wlan ] && rm -rf rtl8821cu_wlan
		git clone https://github.com/andydvsn/rtl8821cu_wlan.git
		mkdir -p lib/modules/$KOURNAME/kernel/drivers/net/wireless
		sed -i 's/KVER  := $(shell uname -r)/KVER  := '$KOURNAME'/g' "./rtl8821cu_wlan/Makefile"
		cd rtl8821cu_wlan
		make -j`nproc`
		cd ..
		cp rtl8821cu_wlan/rtl8821cu.ko lib/modules/$KOURNAME/kernel/drivers/net/wireless
		rm -rf rtl8821cu_wlan

		## RTL8821CU Bluetooth Support
		[ -d rtl8821cu_bt ] && rm -rf rtl8821cu_bt
		git clone https://github.com/andydvsn/rtl8821cu_bt.git
		mkdir -p lib/modules/$KOURNAME/kernel/drivers/bluetooth
		cd rtl8821cu_bt/bluetooth_usb_driver
		make -C /lib/modules/$KOURNAME/build M=`pwd` modules
		cd ../..
		cp rtl8821cu_bt/bluetooth_usb_driver/rtk_btusb.ko lib/modules/$KOURNAME/kernel/drivers/bluetooth
		rm -rf rtl8821cu_bt

	fi

	## Firmware Hub Module
	[ -d fh ] && rm -rf fh
	git clone https://github.com/andydvsn/fh.git
	mkdir -p lib/modules/$KOURNAME/extra
	cd fh
	make -C /lib/modules/$KOURNAME/build M=`pwd` modules
	cd ..
	cp fh/fh.ko lib/modules/$KOURNAME/extra
	rm -rf fh

	echo
	echo "`date  +'%Y-%m-%d %H:%M:%S'`: Companion modules done, but check the log above. Compressing and moving..."
	tar zcvf modules-$KOURNAME.tgz lib
	rm -rf lib
	mv modules-$KOURNAME.tgz $KDLPATH

	echo
	cleanup
	echo
	echo "`date  +'%Y-%m-%d %H:%M:%S'`: Companion modules ready."
	echo
	echo

fi

if [[ "$IBUILDIT" == 0 ]]; then

	echo "`date  +'%Y-%m-%d %H:%M:%S'`: Image for kernel $KOURNAME has already been processed."

else

	if [ -d $$IDLPATH ]; then
		echo -n "`date  +'%Y-%m-%d %H:%M:%S'`: Removing outdated ${IDISTNAME^} ${ICODENAME^} $KOURNAME image..."
		rm -rf $$IDLPATH
		echo " done."
	fi

	echo "`date  +'%Y-%m-%d %H:%M:%S'`: Building ${IDISTNAME^} ${ICODENAME^} $KOURNAME image..."
	echo

	rm -rf ./*.img*

	$THISSCRIPTPATH/of-imgcreate.sh "$(echo ${ICODENAME,,} | head -c 3)" ext2 1 uni 32 0 "${IDISTNAME,,} ${ICODENAME,,}" "$THISSCRIPTPATH/../$GITREPOLIN/overlay-${IDISTNAME,,}-${ICODENAME,,}" "$KDLPATH" "$IDOWNLURL"

	# This checks through the exit codes so far and kills us if any have been greater than zero.
	RCS=${PIPESTATUS[*]}; RC=0; for i in ${RCS}; do RC=$(($i > $RC ? $i : $RC)); done
	if [[ $RC -gt 0 ]]; then
		echo -n "`date  +'%Y-%m-%d %H:%M:%S'`: Build failed, check the log."
		cleanup
		exit $RC
	fi

	echo -n "`date  +'%Y-%m-%d %H:%M:%S'`: Compressing and checkumming..."
	IBUILTIT=`ls | grep -m 1 .img`
	gzip $IBUILTIT
	md5sum $IBUILTIT.gz > $IBUILTIT.gz.md5
	echo " done."
	echo -n "`date  +'%Y-%m-%d %H:%M:%S'`: Moving to webserver..."
	mkdir -p $IDLPATH
	mv ./*.img* $IDLPATH
	[ -L "$PATHTODOWNLOADAREA/images/${IDISTNAME,,}/latest_$KLATESTMAJVER$KLATESTMIDVER" ] && rm "$PATHTODOWNLOADAREA/images/${IDISTNAME,,}/latest_$KLATESTMAJVER$KLATESTMIDVER"
	[ -L "$PATHTODOWNLOADAREA/images/${IDISTNAME,,}/${ICODENAME,,}/latest_$KLATESTMAJVER$KLATESTMIDVER" ] && rm "$PATHTODOWNLOADAREA/images/${IDISTNAME,,}/${ICODENAME,,}/latest_$KLATESTMAJVER$KLATESTMIDVER"
	ln -s "$IDLPATH" "$PATHTODOWNLOADAREA/images/${IDISTNAME,,}/latest_$KLATESTMAJVER$KLATESTMIDVER"
	echo " done."
	echo
	echo "`date  +'%Y-%m-%d %H:%M:%S'`: Image build completed."
	echo
	echo

fi

cleanup

exit 0
