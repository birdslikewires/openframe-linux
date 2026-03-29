# Linux for OpenFrame

These are the overlays and scripts used to create system images for OpenFrame devices; notably the *OpenFrame 1,* sold in the UK as the **O2 Joggler**, and *OpenFrame 2,* which were used for energy monitoring, home automation, and telephony purposes.

In addition, this repository also builds Debian Trixie system images for these devices, which are available on the [Releases](https://github.com/birdslikewires/openframe-linux/releases) page. Some older versions based on Bullseye and Bookworm are still available on [openbeak.net](https://openbeak.net/openframe/images/).


## Overlays

The overlay files modify the vanilla system to provide some necessary and some nice-to-have features, including automatically configured GRUB, network settings from the `/boot` volume (ideal for preconfiguring), sensible system defaults, and minimal firmware files.

It should be possible to use updated microcode for the Intel Atom Z520, if that's of concern to you. The microcode you need is `06-1c-02` from [Intel's repository](https://github.com/intel/Intel-Linux-Processor-Microcode-Data-Files/tree/main/intel-ucode). If you have any luck, let me know.


## Scripts

Some of these are more useful than others, depending upon your build environment. You'll definitely want `of-imgcreate.sh`, while the others are mostly for self-hosted setups or building an image manually.

### of-builder.sh

So you want to automatically build images for OpenFrame devices on your server? This is the script for you.

The OpenFrame devices are all 32-bit, so you're going to need a i386 environment. Our solution is to create a 32-bit chroot on a 64-bit system. For Debian Trixie it can be achieved like this:

```
sudo apt install debootstrap schroot
sudo nano /etc/schroot/chroot.d/i386.conf
```

Copy in:

```
[i386]
description=i386
type=directory
union-type=overlay
directory=/var/lib/schroot/chroots/i386
personality=linux32
groups=root,sudo
root-groups=root,sudo
```

Then install the base system with debootstrap:

```
sudo mkdir -p /var/lib/schroot/chroots/i386
sudo debootstrap --arch=i386 trixie /var/lib/schroot/chroots/i386 http://deb.debian.org/debian
```

Hop in to the chrooted environment like this:

```
sudo schroot -c source:i386
```

You can then complete the setup of your build environment.

```
rm /var/lib/dpkg/statoverride 
rm /var/lib/dpkg/lock
dpkg --configure -a
apt update && apt upgrade
apt install autoconf bc bison build-essential curl debhelper debootstrap dosfstools flex git libelf-dev libncurses5-dev libssl-dev lsb-release parted rsync wget 
```

The build server runs a command like this from its crontab:

```
1 1 * * * schroot -c i386 -u root -- bash -c "cd /home/debian/build ; /home/debian/openframe-linux/of-builder.sh 'debian' 'bookworm' 'http://deb.debian.org/debian' '6.1' '/home/debian/www' &> /home/debian/www/logs/bookworm-6.1_`date +'\%Y-\%m-\%d-\%H\%M'`.txt"
```


### of-cnc.sh

This script provides a handy method of copying everything back from a storage device for packaging up into a .tgz. That .tgz can then magically be used by __ofimgcreate.sh__ to generate a reasonably fresh image.


### of-imgcreate.sh

This script does the hard work of creating an image file of a given size, creating  filesystem on it, mounting it, and then going on to fetch and install Ubuntu using debootstrap.

You will also need the overlay files provided in this repo and some working kernel image packages.


### of-imgmnt.sh

Used to mount image files for minor tweaks, meaning we don't need to rebuild things every time. Now with variable partition support!


### of-serverclean.sh

Basic build server cleaning script. Give it directories to clean line-by-line in a text file and once server drive space drops below 5 GB it removes any directories (and obviously their contents) that are older than 12 months.


