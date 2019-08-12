#!/bin/bash

## of-builder.sh v1.04 (12th August 2019)
##  Grabs a kernel, patches it, builds it.

if [ $# -lt 1 ]; then
	echo "Usage: $0 <kernelbranch> [codename]"
	exit 1
fi

source /etc/lsb-release

## Configurable Bits

OURVER="op"
PATHTODOWNLOADAREA="/home/andy/Public/download_blw/openframe"
COREDIVIDER=1

## Everything Else

KBRANCH="$1"
KARCHIVES=`curl --silent https://www.kernel.org/index.html`
KDOWNLOAD=`echo "$KARCHIVES" | grep -m 1 "linux-$KBRANCH" | grep ".xz" | awk -F\" {'print $2'}`

if [[ ! "$KDOWNLOAD" ]]; then
	echo "Kernel branch $KBRANCH was not found as stable or longterm on the kernel.org homepage."
	exit 1
fi

KFILENAME=`echo "$KDOWNLOAD" | sed 's:.*/::'`
KLATESTMAJVER=`echo "$KFILENAME" | awk -F\- {'print $2'} | awk -F\. {'print $1'}`
KLATESTMIDVER=`echo "$KFILENAME" | awk -F\- {'print $2'} | awk -F\. {'print $2'}`
KLATESTMINVER=`echo "$KFILENAME" | awk -F\- {'print $2'} | awk -F\. {'print $3'}`
KOURNAME="$KLATESTMAJVER.$KLATESTMIDVER.$KLATESTMINVER$OURVER"
KOURBUILD="linux-$KLATESTMAJVER.$KLATESTMIDVER.$KLATESTMINVER"
KDLPATH="$PATHTODOWNLOADAREA/kernel/ubuntu/$DISTRIB_CODENAME/$KLATESTMAJVER.$KLATESTMIDVER/$KOURNAME"
[ -d $KDLPATH ] && KBUILDIT=0 || KBUILDIT=1

ICODENAME="$2"
IDLPATH="$PATHTODOWNLOADAREA/images/ubuntu/${ICODENAME,,}/$KLATESTMAJVER.$KLATESTMIDVER/$KOURNAME"
[ -d $IDLPATH ] && IBUILDIT=0 || IBUILDIT=1

## Work To Do!

cleanup() {
	echo -n "`date  +'%Y-%m-%d %H:%M:%S'`: Cleaning up..."
	chown -R www-data:www-data $PATHTODOWNLOADAREA/kernel $PATHTODOWNLOADAREA/images
	chmod -R 774 $PATHTODOWNLOADAREA/kernel $PATHTODOWNLOADAREA/images
	rm -rf ./$KOURBUILD*
	rm -rf ./*.deb
	rm -rf ./*.img*
	rm -rf ./tmp
	echo " done."
}

if [ ! -d openframe-kernel ]; then
	git clone https://github.com/andydvsn/openframe-kernel.git
	echo
#else
#	cd openframe-ubuntu ; git pull > /dev/null ; cd ..
fi
if [ ! -d openframe-ubuntu ]; then
	git clone https://github.com/andydvsn/openframe-ubuntu.git
	echo
#else
#	cd openframe-ubuntu ; git pull > /dev/null ; cd ..
fi

if [[ "$KBUILDIT" == 0 ]]; then

	echo "`date  +'%Y-%m-%d %H:%M:%S'`: Kernel $KBRANCH has already been processed as $KOURNAME."

else

	echo "`date  +'%Y-%m-%d %H:%M:%S'`: Building $KOURNAME kernel..."
	echo

	if [ ! -f "$KFILENAME" ]; then
		echo -n "Downloading $KFILENAME..."
		echo
		wget "$KDOWNLOAD"
		echo
	else
		echo "Kernel archive $KFILENAME found."
	fi

	if [ ! -f "$KFILENAME" ]; then
		echo "Download appears to have failed."
		exit 1
	fi

	if [ -d "$KOURBUILD" ]; then
		echo -n "Removing previous build cruft..."
		rm -rf "$KOURBUILD"
		rm -rf *.deb
		rm -rf ./tmp/*
		echo " done."
	fi

	echo -n "Decompressing $KFILENAME..."
	tar xJf $KFILENAME
	echo " done."

	echo "Applying OpenFrame kernel patches..."
	for p in `ls openframe-kernel/patches/$KLATESTMAJVER.$KLATESTMIDVER`; do
		patch -f -p1 -d "$KOURBUILD" < "openframe-kernel/patches/$KLATESTMAJVER.$KLATESTMIDVER/$p"
	done

	# This checks through the exit codes so far and kills us if any have been greater than zero.
	RCS=${PIPESTATUS[*]}; RC=0; for i in ${RCS}; do RC=$(($i > $RC ? $i : $RC)); done
	[[ $RC -gt 0 ]] && exit $RC

	echo -n "Applying extraversion to makefile..."
	KMAKEFILE=`cat "$KOURBUILD/Makefile"`
	if [[ ! "$KMAKEFILE" =~ "EXTRAVERSION = $OURVER" ]]; then
		sed -i "s/EXTRAVERSION =/EXTRAVERSION = $OURVER/g" "$KOURBUILD/Makefile"
	fi
	echo " done."

	echo "Updating config file with new defaults..."
	KCONFIGFILE=`ls openframe-kernel/configs | grep "$KLATESTMAJVER.$KLATESTMIDVER"`
	cp "openframe-kernel/configs/$KCONFIGFILE" "$KOURBUILD/.config"
	cd "$KOURBUILD"
	make olddefconfig

	echo
	echo "Go! Go! Go!"
	echo
	make -j$((`nproc`/$COREDIVIDER)) deb-pkg

	RCS=${PIPESTATUS[*]}; RC=0; for i in ${RCS}; do RC=$(($i > $RC ? $i : $RC)); done
	if [[ $RC -gt 0 ]]; then
		echo
		echo "Build failed, check the log."
		cleanup
		exit $RC
	fi

	echo
	echo "Build succeeded!"
	echo

	mkdir -p $KDLPATH
	cd ..
	echo -n "Moving kernel $KOURNAME packages..."
	mv *.deb $KDLPATH
	echo " done."
	echo -n "Copying kernel $KOURNAME config file..."
	cp "$KOURBUILD/.config" "$KDLPATH/$KOURNAME.config"
	echo " done."
	echo -n "Copying kernel $KOURNAME patches..."
	cp -R "openframe-kernel/patches/$KLATESTMAJVER.$KLATESTMIDVER" "$KDLPATH/patches"
	echo " done."
	echo
	cleanup
	echo
	echo "`date  +'%Y-%m-%d %H:%M:%S'`: Kernel compiled, packages ready."

fi

if [ -f $KDLPATH/modules-$KOURNAME.tgz ]; then

	echo "`date  +'%Y-%m-%d %H:%M:%S'`: Companion modules for kernel $KOURNAME have already been processed."

else

	echo "`date  +'%Y-%m-%d %H:%M:%S'`: Building $KOURNAME kernel companion modules..."

	[ ! -d /lib/modules/$KOURNAME ] && dpkg -i $KDLPATH/linux-headers*

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
	#sed -i 's/KVER  := $(shell uname -r)/KVER  := '$KOURNAME'/g' "./rtl8821cu_bt/bluetooth_usb_driver/Makefile"
	cd rtl8821cu_bt/bluetooth_usb_driver
	#make -j`nproc`
	make -C /lib/modules/$KOURNAME/build M=`pwd` modules
	cd ../..
	cp rtl8821cu_bt/bluetooth_usb_driver/rtk_btusb.ko lib/modules/$KOURNAME/kernel/drivers/bluetooth
	rm -rf rtl8821cu_bt

	## Firmware Hub Module
	[ -d fh ] && rm -rf fh
	git clone https://github.com/andydvsn/fh.git
	mkdir -p lib/modules/$KOURNAME/extra
	cd fh
	make -C /lib/modules/$KOURNAME/build M=`pwd` modules
	cd ..
	cp fh/fh.ko lib/modules/$KOURNAME/extra
	rm -rf fh

	tar zcvf modules-$KOURNAME.tgz lib
	rm -rf lib

	mv modules-$KOURNAME.tgz $KDLPATH

	exit 0

fi

if [[ "$IBUILDIT" == 0 ]]; then

	echo "`date  +'%Y-%m-%d %H:%M:%S'`: Image for kernel $KOURNAME has already been processed."

else

	echo "`date  +'%Y-%m-%d %H:%M:%S'`: Building Ubuntu ${ICODENAME^} $KOURNAME image..."
	echo

	rm -rf ./*.img*

	openframe-ubuntu/of-imgcreate.sh `echo ${ICODENAME,,} | head -c 3` ext2 1 uni 32 0 ${ICODENAME,,} openframe-ubuntu/overlay-${ICODENAME,,} $KDLPATH

	# This checks through the exit codes so far and kills us if any have been greater than zero.
	RCS=${PIPESTATUS[*]}; RC=0; for i in ${RCS}; do RC=$(($i > $RC ? $i : $RC)); done
	if [[ $RC -gt 0 ]]; then
		echo -n "Build failed, check the log."
		cleanup
		exit $RC
	fi

	echo -n "Compressing and checkumming..."
	IBUILTIT=`ls | grep -m 1 .img`
	gzip $IBUILTIT
	md5sum $IBUILTIT.gz > $IBUILTIT.gz.md5
	echo " done."
	echo -n "Moving to webserver..."
	mkdir -p $IDLPATH
	mv ./*.img* $IDLPATH
	echo "$IDLPATH"
	[ -L "$PATHTODOWNLOADAREA/images/ubuntu/latest" ] && rm "$PATHTODOWNLOADAREA/images/ubuntu/latest"
	[ -L "$PATHTODOWNLOADAREA/images/ubuntu/${ICODENAME,,}/latest" ] && rm "$PATHTODOWNLOADAREA/images/ubuntu/${ICODENAME,,}/latest"
	ln -s "$IDLPATH" "$PATHTODOWNLOADAREA/images/ubuntu/latest"
	echo " done."
	echo
	echo "`date  +'%Y-%m-%d %H:%M:%S'`: Image build completed."

fi

cleanup

exit 0
