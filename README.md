Ubuntu for OpenFrame
====================

These are the scripts and overlays which I use to create debootstrapped operating systems for OpenFrame devices, notably the OpenFrame 1 (sold in the UK as the O2 Joggler) and OpenFrame 2.


ofimgcreate.sh
--------------

This script does the hard work of creating an image file of a given size, creating  filesystem on it, mounting it, and then going on to fetch and install Ubuntu using debootstrap. It's usage is as follows:

	ofimgcreate.sh <name> <filesystem> <totalMB> <bootMB> <swapMB> [ <tgz|dbsver> [overlay] [kerneldir] ]

So, if you wish to create a 2GB Ubuntu Trusty image with no swap:

	ofimgcreate.sh trusty ext2 2048 32 0 trusty overlay-trusty kernel-ver

You will also need the overlay files provided in this repo, plus working kernel image packages.

###Kernel###

The [vanilla kernel](http://kernel.org "kernel.org") will work, just not very well. For full support, you can download [patches, config files and kernels I have compiled](http://birdslikewires.co.uk/download/openframe/kernel). What's missing on anything later than kernel 3.2 is the ability to compile Intel's EMGD drivers. Luckily we have the GMA500 kernel drivers working, but you won't get 3D or hardware video decoding. Please shout at Intel.

If you require snazzy video functionality, you'll need either the 3.2 kernel and some luck, or just [go and download BuZz's precompiled images](http://joggler.exotica.org.uk).


ofcnc.sh
--------

Some things are best done on a running Joggler (eg. compiling drivers) so this script provides a handy method of copying everything back from a device for packaging up into a .tgz. That .tgz can then magically be used by __ofimgcreate.sh__ to generate another new image.

Snazzy, huh? ;)