# Linux for OpenFrame

This repository builds Debian Trixie images with modern kernels for OpenFrame devices; notably the *OpenFrame 1,* which was sold in the UK as the **O2 Joggler**, and the *OpenFrame 2,* which were used under various guises for energy monitoring, home automation, and telephony purposes.

Image files are available on the [Releases](https://github.com/birdslikewires/openframe-linux/releases) page. Some older versions based on Bullseye and Bookworm are still available on [openbeak.net](https://openbeak.net/openframe/images/), alongside other resources, such as the original firmware images and EFI files.

All of the overlays and scripts used to create the image files are in this repo, with deprecated versions for earlier versions of Debian if we wander back through the commits.


## First-Boot Provisioning

Images include `of-provision`, a first-boot mechanism for installing software without baking every combination of packages into the image itself.

To use it, place a `setup.txt` file in the `OF-BOOT` volume before first boot, containing a single line: the URL of the project you want installed, e.g.

```
https://github.com/birdslikewires/openframe-hamclock
```

For a GitHub project URL like this, `of-provision` works out the raw `install.sh` URL itself, trying the `main` branch and then falling back to `master`. For anything hosted elsewhere, it looks for `install.sh` at the root of the given URL, e.g. `https://example.com/my-openframe-app/` is expected to have an installer at `https://example.com/my-openframe-app/install.sh`.

On first boot, the `of-provision.service` systemd unit checks for `/boot/setup.txt`. If it's present, it downloads the resulting `install.sh` and runs it as the `of` user, logging output to `/var/log/setup.log`. The device then reboots automatically.

The service disables itself immediately upon firing, regardless of whether the installer succeeds, so it will not run again on subsequent boots. Depending on the outcome, `setup.txt` is either removed (success), renamed to `setup.txt.failed` (installer error or download failure), or renamed to `setup.txt.rejected` (file was empty).

To provision another install after first run, re-enable the service and restore `setup.txt`:

```
sudo systemctl enable of-provision.service
sudo of-settings bootrw enable                   # /boot is normally read-only
sudo mv /boot/setup.txt.failed /boot/setup.txt   # or recreate it with a new URL
sudo reboot
```


## Configuration

### Locale and Timezone

Images default to the `C.UTF-8` locale and UTC timezone. To configure for your local environment:

```
sudo dpkg-reconfigure locales
sudo dpkg-reconfigure tzdata
```

Running `dpkg-reconfigure locales` will present a menu to generate and select a locale (e.g. `en_GB.UTF-8` for the UK), while `dpkg-reconfigure tzdata` lets you select your timezone (e.g. Europe/London).


## Overlays

The overlay files modify the vanilla system to provide some necessary and some nice-to-have features, including automatically configured GRUB, network settings from the `/boot` volume (ideal for preconfiguring), sensible system defaults, and minimal firmware files.

Firmware in `/usr/lib/firmware/updates` is part of the `openframe-scripts` package, so existing systems get changes to it too. It holds `stac9202.patch`, which sets up the audio codec's headphone and speaker pins on both the OpenFrame 1 and 2. It also holds files that the kernel's built-in drivers list but Debian doesn't ship yet, such as `rtl_nic/rtl8127a-1.fw` for r8169. The OpenFrame doesn't use those, but without them every initramfs rebuild warns "Possible missing firmware".

The firmware's EFI shell starts the kernel directly through its EFI stub rather than through GRUB, which loads the kernel and initrd about five times faster and saves around ten seconds per boot. Because the shell only starts `.efi` files and the boot volume has no room for a second copy, the kernel is kept as `/boot/vmlinuz.efi`; the kernel hooks and `of-bootnsh` look after this. An empty `vmlinuz-<version>` stays in its place so that `update-initramfs` can still find the kernel. After each kernel upgrade, older kernels and `System.map` are removed from `/boot`, so there's always room to rebuild the initrd and install the next kernel. Systems on earlier images switch over the first time the `openframe-scripts` package updates. Run `sudo of-settings efistub disable` to boot through GRUB instead.

GRUB is otherwise only a safety net for the internal memory. The stock firmware freezes loading a file the size of the kernel from there, which BirdsLikeWires firmware 26.11.22 and later fixes, and `BlwMmcFix.efi` fixes for the stock firmware until the next reset. Only if neither applies does a system on the internal memory boot through GRUB, which reads the kernel in small pieces. It's GRUB 2.12, built from Debian's `grub-efi-ia32-bin` by `of-grubbuild.sh`, and quiet: nothing shows on the screen. Images start the kernel directly from their first boot, and those built for the internal memory have GRUB after `BlwMmcFix.efi`.

Every `boot.nsh` first switches the shell to its own volume, which it finds by a marker file named after its boot partition (`ofboot-<partition UUID>`). Without that, a file named without a volume is looked for on the shell's current volume, which is the internal memory: a stick's `boot.nsh` would start the internal memory's kernel or GRUB if it had one.

On its first boot each system also gives its disk identifiers (partition-table ID, labels and filesystem UUIDs) random values, and names its partitions by partition UUID from then on. A stick and the internal memory written from the same image then never mistake each other's partitions for their own.

OpenFrames often lose power without warning, so the system is built to shrug that off. The root filesystem is ext4, whose journal replays in a moment after a power cut (systems on earlier ext2 images gain a journal the first time `openframe-scripts` updates), and the kernel lets the boot-time check repair anything else without asking. `/boot` is FAT, which has no journal, so it's mounted read-only and checked at boot: package installs and the OpenFrame scripts make it writable only while they write to it, and it's mounted `dirsync`, so a cut mid-write leaves the old file or the new one. If a cut interrupts a package installation, `of-dpkg-recover` finishes it or reinstalls the package at the next boot, downloading it once the network is up if it has to. To change something on `/boot` by hand, make it writable first with `sudo of-settings bootrw enable`; `sudo of-settings bootrw disable`, or the next boot, puts it back.

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


