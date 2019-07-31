Ubuntu for OpenFrame
=====================

These are the scripts and overlays which I use to create debootstrapped operating systems for OpenFrame devices, notably the OpenFrame 1 (sold in the UK as the O2 Joggler) and OpenFrame 2.


ofcnc.sh
---------

This script provides a handy method of copying everything back from a storage device for packaging up into a .tgz. That .tgz can then magically be used by __ofimgcreate.sh__ to generate a reasonably fresh image.


ofimgcreate.sh
---------------

This script does the hard work of creating an image file of a given size, creating  filesystem on it, mounting it, and then going on to fetch and install Ubuntu using debootstrap.

You will also need the overlay files provided in this repo and some working kernel image packages.


ofimgmnt.sh
------------

Used to mount image files for minor tweaks, meaning we don't need to rebuild things every time. Now with variable partition support!

