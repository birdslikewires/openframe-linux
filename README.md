# Linux for OpenFrame

This repository builds Debian Trixie images with modern kernels for OpenFrame devices; notably the *OpenFrame 1,* which was sold in the UK as the **O2 Joggler**, and the *OpenFrame 2,* which were used under various guises for energy monitoring, home automation, and telephony purposes.

Image files are available on the [Releases](https://github.com/birdslikewires/openframe-linux/releases) page. Some older versions based on Bullseye and Bookworm are still available on [openbeak.net](https://openbeak.net/openframe/images/), alongside other resources, such as the original firmware images and EFI files.

All of the overlays and scripts used to create the image files are in this repo, with deprecated versions for earlier versions of Debian if we wander back through the commits.

Images start into [Sprite](https://github.com/birdslikewires/openframe-sprite), the touch shell: a home screen of apps and settings, with one app at a time full screen. It can open one app at startup instead, for an OpenFrame with a single job. The login prompt is still there over SSH, and comes back on the screen if Sprite is removed (`sudo apt remove openframe-sprite`) or keeps failing.


## First-Boot Provisioning

Images include `of-provision`, a first-boot mechanism for installing software without baking every combination of packages into the image itself.

To use it, fill in `setup.txt` in the `settings` folder of the `OF-BOOT` volume before first boot: `project=` and the address of the project you want installed, e.g.

```
project=https://github.com/birdslikewires/openframe-hamclock
```

For a GitHub project like this, `of-provision` works out the raw `install.sh` URL itself, trying the `main` branch and then falling back to `master`. To pin a release, tag or branch, give its address on GitHub instead (`https://github.com/owner/project/tree/v1.2`, or `.../releases/tag/v1.2`), and that version's `install.sh` is used; a link to an `install.sh` on GitHub (`.../blob/<ref>/install.sh`) or anywhere else is used as it is. For anything else hosted elsewhere, it looks for `install.sh` at the root of the given URL, e.g. `https://example.com/my-openframe-app/` is expected to have an installer at `https://example.com/my-openframe-app/install.sh`.

Any other lines in `setup.txt` are settings for the project's installer, passed to `install.sh` as environment variables named `SETUP_` and the setting's name in capitals: `name=Kitchen` arrives as `SETUP_NAME=Kitchen`. A project that wants settings says which in its instructions.

On first boot, the `of-provision.service` systemd unit checks `/boot/settings/setup.txt` (or `/boot/setup.txt`, as on older images, where it holds just the address on a line of its own; that still works). If it names a project, it downloads the resulting `install.sh` and runs it as the `of` user, logging output to `/var/log/setup.log`. The device then reboots automatically. With no project, nothing happens and `setup.txt` stays as it is.

The service disables itself as soon as it fires, so it only runs on the first boot. A download that fails (the network not up yet, say) is tried again at the next boot, three boots in all. On success `setup.txt` is removed; if the downloads fail or the installer exits with an error, it's renamed to `setup.txt.failed`, the reason is shown on the login screen, and, on a system running from a USB stick, the log is copied to `settings/setup.log`, where a computer can read it.

To provision another install after first run, re-enable the service and restore `setup.txt` (systems from images before November 2026 only look for it in the root, `/boot/setup.txt`):

```
sudo systemctl enable of-provision.service
sudo of-settings bootrw enable                   # /boot is normally read-only
sudo mv /boot/settings/setup.txt.failed /boot/settings/setup.txt   # or recreate it with a new URL
sudo reboot
```


## OpenFrame Flash: Installing onto an OpenFrame's Internal Memory

The image is also a flash stick, with OpenFrame Flash. Written to a USB stick (4 GB or more), it can install itself onto an OpenFrame 1's or OpenFrame 2's internal memory and bring the firmware up to date, without a network, and then go on to the next unit:

1. Write the image to the stick. In the `settings` folder of `OF-BOOT`, set `flash=yes` in `flash.txt`, and fill in any other settings for the unit (`wifi.txt`, `ethernet.txt`, `setup.txt` and so on).
2. Put the stick in the OpenFrame and switch it on. The first time, the rest of the stick becomes a drive called `OF-BACKUP`. The screen says what's happening; don't switch off. The firmware and the internal memory are backed up to `OF-BACKUP` first, in a folder for the unit, and checked. If the firmware needs updating, that happens next and the OpenFrame restarts by itself. Then the new system is written to the internal memory and checked, and the stick's settings are copied onto it.
3. When it says it's done and switches off, remove the stick. The OpenFrame starts its new system, with the settings from step 1.
4. Back on the computer, the stick's settings are blank again (`flash.txt` still says yes), and `OF-BACKUP` has the unit's folder: `mmc.img.gz` (the internal memory as it was), `firmware.bin` and `info.txt`. Fill in the next unit's settings and repeat. A unit the stick has already done is left alone; set `flash=again` to install it again.

An OpenFrame 2's internal memory is twice an OpenFrame 1's (2 GB): the new system grows into the rest of it at its first start, and its backup takes twice the room and time. Its firmware goes to the OpenFrame 2 release, built on the Telio firmware, keeping the unit's own display driver.

With `backup=no` in `flash.txt`, only the firmware is backed up (a few seconds), not the internal memory, which saves a couple of minutes on a unit whose system is being thrown away anyway. The stick then doesn't make `OF-BACKUP`: its system fills the stick, so it can be used as a system too, and installs again whenever `flash.txt` says `flash=yes`.

Firmware the updater doesn't recognise is never touched, and the install stops before writing anything. Anything else that stops it says why on the screen and in the unit's `info.txt`. A power cut or restart part way through carries on from where it got to.

A stick that has been started as a system (without `flash=yes` the first time, or with `backup=no`) grows into the space `OF-BACKUP` would have had. It can still install while it carries the image copy: set `flash=yes`, and the units' folders, with their backups unless `backup=no`, go on the stick's own system in `/var/lib/openframe-flash/backups` (copy them off over SSH). A unit it has already done just starts the stick's system. `sudo of-flash flash` does the same by hand. `sudo of-flash backup` backs a unit up without installing anything; `sudo of-flash status` shows what the stick can do and what it has installed; `sudo of-flash clean` removes the copy of the image the stick carries (about 130 MB), which also happens by itself on a stick in use as a system that's running short of space.


## Configuration

### Settings on OF-BOOT

The `settings` folder in the `OF-BOOT` volume holds everything meant to be changed from any computer before (or after) the OpenFrame boots:

- `wifi.txt`: the name and password of the Wi-Fi network to join (leave the password empty for an open network), and optionally a fixed address.
- `ethernet.txt`: optionally a fixed address for the wired network.
- `backlight.txt`: settings for automatic brightness (`of-backlight auto`), such as night hours and when the screen turns off in the dark. Changes take effect within ten seconds.
- `network.yaml` (not there unless you add it): a full [netplan](https://netplan.io) configuration, for anything the `.txt` files can't do, such as several Wi-Fi networks. It's used as it is, and `wifi.txt` and `ethernet.txt` only fill in what it doesn't set up. If netplan can't use it, the network carries on without it and the login prompt says what's wrong.

In `wifi.txt` and `ethernet.txt`, leave `address`, `gateway` and `dns` empty for an address from the router (DHCP). For a fixed one, give the address with its prefix or mask (`192.168.1.50/24`, `192.168.1.50/255.255.255.0`, or just `192.168.1.50` for a /24) and the gateway (usually your router's address). DNS is the gateway unless you list servers, separated by commas; servers listed with an automatic address replace the router's. A setting that isn't right is ignored (the network stays automatic), and the login prompt says so, as does Sprite, with an amber warning in its status bar. With both networks connected, the wired one carries the traffic.
- `setup.txt`: a project to install when the system first starts, and any settings for it; see First-Boot Provisioning.
- `sprite.txt`: Sprite's settings: `startup=` names an app to open whenever the OpenFrame starts, instead of the home screen (holding an app's tile and choosing "Open at startup" sets it too), and `calibration=` holds the touchscreen calibration from Sprite's Settings.
- `ssh.txt`: logging in as `of`. `password=` sets its password (for SSH and `sudo`) at the next start, and is then emptied in the file, so the password never stays on `OF-BOOT`, which anyone can read; `key=` lines are public keys allowed to log in (the whole of a `.pub` file each), applied at every start. Images give `of` no password (every unit used to have the same one, `joggler`), so until one is set, here or in Sprite's Settings, SSH needs a key; and until anyone can log in (a password or a key for a person's account, or a key for root), the SSH server doesn't start, so a new unit isn't listening with no way in. Setting a password in Sprite's Settings starts it. `sudo` needs no password: `of` is the person's account, and nothing runs as it unless someone's logged in (Sprite runs as a user of its own). On a flash stick the password stays in `ssh.txt`, so that each unit the stick installs gets it (and empties it in its own). Units set up before 22 November 2026 keep the password they had.
- `flash.txt`: `flash=yes` makes the stick install itself onto an OpenFrame's internal memory, and `backup=no` leaves out the internal memory's backup; see above. It's removed from the internal memory's system, and from a stick once it no longer carries the image copy.

Older images kept `network.yaml` and `backlight.txt` in the root of `OF-BOOT`. They move into `settings` once `openframe-scripts` is updated: a `network.yaml` with only the Wi-Fi name and password filled in becomes `wifi.txt`, and one with more in it becomes `settings/network.yaml`. The same happens to a `network.yaml` copied into the root of a new image. The MAC address isn't written into it any more.

### Locale and Timezone

Images default to the `C.UTF-8` locale and UTC timezone. To configure for your local environment:

```
sudo dpkg-reconfigure locales
sudo dpkg-reconfigure tzdata
```

Running `dpkg-reconfigure locales` will present a menu to generate and select a locale (e.g. `en_GB.UTF-8` for the UK), while `dpkg-reconfigure tzdata` lets you select your timezone (e.g. Europe/London).

### Automatic Updates

OpenFrames keep themselves up to date: Debian's updates, and OpenBeak's (Sprite, these scripts, the kernel and the firmware), installed by `unattended-upgrades` through `of-update`, so owners never need to log in for them.

- **When:** every night at a time of the unit's own between 01:00 and 03:00 (`of-update-night.timer`), and ten minutes after a start if the last good update was over 20 hours ago (`of-update-catchup.timer`), for units that are off at night or only on now and then.
- **How:** the package lists, then every download, then the installing, a package at a time (`MinimalSteps`), so a power cut leaves little half-done, and `of-dpkg-recover` finishes it at the next start. Settings files changed on the unit are kept. The settings are in `/etc/apt/apt.conf.d/52openframe-updates`; apt's own daily timers are off.
- **Restarts:** a new kernel, or firmware to flash, takes effect at the next restart (`/run/reboot-required`, the Debian way). The unit restarts by itself between 04:00 and 04:30 when one's needed (`of-update-reboot.timer`), never while an update is being installed.
- **Sprite** shows it all in Settings, under Updates: what's happening, with progress, what's waiting, and buttons to check, update or restart now. `sudo of-update status` says the same over SSH, and `sudo of-update run now` updates straight away.
- To stop it: `sudo systemctl disable --now of-update-night.timer of-update-catchup.timer of-update-reboot.timer` (enabled once per system, so that sticks).


## Overlays

The overlay files modify the vanilla system to provide some necessary and some nice-to-have features, including automatically configured GRUB, network settings from the `/boot` volume (ideal for preconfiguring), sensible system defaults, and minimal firmware files.

Firmware in `/usr/lib/firmware/updates` is part of the `openframe-scripts` package, so existing systems get changes to it too. It holds `stac9202.patch`, which sets up the audio codec's headphone and speaker pins on both the OpenFrame 1 and 2. It also holds files that the kernel's built-in drivers list but Debian doesn't ship yet, such as `rtl_nic/rtl8127a-1.fw` for r8169. The OpenFrame doesn't use those, but without them every initramfs rebuild warns "Possible missing firmware".

The firmware's EFI shell starts the kernel directly through its EFI stub rather than through GRUB, which loads the kernel and initrd about five times faster and saves around ten seconds per boot. Because the shell only starts `.efi` files and the boot volume has no room for a second copy, the kernel is kept as `/boot/vmlinuz.efi`; the kernel hooks and `of-bootnsh` look after this. An empty `vmlinuz-<version>` stays in its place so that `update-initramfs` can still find the kernel. After each kernel upgrade, older kernels and `System.map` are removed from `/boot`, so there's always room to rebuild the initrd and install the next kernel. Systems on earlier images switch over the first time the `openframe-scripts` package updates. Run `sudo of-settings efistub disable` to boot through GRUB instead.

GRUB is otherwise only a safety net for the internal memory. The stock firmware freezes loading a file the size of the kernel from there, which BirdsLikeWires firmware 26.11.22 and later fixes, and `BlwMmcFix.efi` fixes for the stock firmware until the next reset. A system on the internal memory runs `BlwMmcFix.efi` before the kernel on any firmware: it succeeds whether it fixed the driver or found it fixed already, so the kernel starts directly whatever is on the firmware chip, even after it was changed by other means. Only if it doesn't recognise the driver does the system boot through GRUB, which reads the kernel in small pieces. It's GRUB 2.12, built from Debian's `grub-efi-ia32-bin` by `of-grubbuild.sh`, and quiet: nothing shows on the screen. Images start the kernel directly from their first boot, and those built for the internal memory have GRUB after `BlwMmcFix.efi`.

`startup.nsh` and `boot.nsh` both first switch the shell to their own volume, which they find by a marker file named after the boot partition (`ofboot-<partition UUID>`); `startup.nsh` then runs its own volume's `boot.nsh`. Without that, a file named without a volume is looked for on whichever volume the shell lists first, which can be the internal memory: a stick's `boot.nsh` would start the internal memory's kernel or GRUB if it had one. With BirdsLikeWires firmware 26.11.30 or later, a USB stick with `startup.nsh` is listed first, so a stick with a system on it always starts itself.

With BirdsLikeWires firmware the unit's MAC address lives in the unit, not on the stick: the firmware keeps it in NVRAM and gives the wired network chip a LAN MAC made from it before any OS starts, along with a UUID and, for a WLAN card, a serial number. With a card it's the card's own MAC (the LAN MAC is `02` then the card's last five octets); with no card it's a MAC generated once for that unit, which every stick in it then uses. If the card is taken out the unit generates a new one rather than keep the card's, which may be in another unit by now, and if the card comes back the unit uses it again. Linux can't write NVRAM, so when it needs a MAC stored, `of-bootnsh` puts `BlwMac.efi` into `boot.nsh` and reboots; `BlwMac.efi` stores the MAC and resets the unit straight away, and the next boot carries on as normal. That happens only when the MAC changes, such as the first boot of a stick in a unit or a card swap, and costs about a minute; an ordinary boot writes nothing.

On its first boot each system also gives its disk identifiers (partition-table ID, labels and filesystem UUIDs) random values, and names its partitions by partition UUID from then on. A stick and the internal memory written from the same image then never mistake each other's partitions for their own.

OpenFrames often lose power without warning, so the system is built to shrug that off. The root filesystem is ext4, whose journal replays in a moment after a power cut (systems on earlier ext2 images gain a journal the first time `openframe-scripts` updates), and the kernel lets the boot-time check repair anything else without asking. `/boot` is FAT, which has no journal, so it's mounted read-only and checked at boot: package installs and the OpenFrame scripts make it writable only while they write to it, and it's mounted `dirsync`, so a cut mid-write leaves the old file or the new one. If a cut interrupts a package installation, `of-dpkg-recover` finishes it or reinstalls the package at the next boot, downloading it once the network is up if it has to. To change something on `/boot` by hand, make it writable first with `sudo of-settings bootrw enable`; `sudo of-settings bootrw disable`, or the next boot, puts it back.

It should be possible to use updated microcode for the Intel Atom Z520, if that's of concern to you. The microcode you need is `06-1c-02` from [Intel's repository](https://github.com/intel/Intel-Linux-Processor-Microcode-Data-Files/tree/main/intel-ucode). If you have any luck, let me know.


## Crystal HD

An OpenFrame 2 with a Broadcom Crystal HD decoder card in its mini PCIe slot can play H.264 video up to 1080p with `chdplay`, from the optional `openframe-crystalhd` package (`sudo apt install openframe-crystalhd`). The package holds the Crystal HD library with our fixes, the card's firmware and the player. The kernel driver comes with the OpenFrame kernel and loads by itself when the card is fitted; see [crystalhd/README.md](crystalhd/README.md).

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

## Licence

This repository is under the GNU General Public License, version 3 or (at your option) any later
version (see [LICENSE](LICENSE)). Copyright 2014-2026 Andrew Davison. It was under the MIT licence
until November 2026, and copies from before then can still be used under those terms. The files
below come from elsewhere and keep their own terms.

- `overlay-*/usr/lib/firmware/updates/brcm/` and `overlay-*/usr/lib/firmware/updates/rtl_nic/`:
  firmware from linux-firmware, each folder with its licence file.
- `overlay-*/usr/lib/firmware/rt2870.bin`: Ralink's firmware for the RT2870, RT3070 and RT5370 USB
  Wi-Fi chips (the `rt2800usb` driver), from linux-firmware, with its licence alongside.
- `overlay-*/usr/lib/openframe/grubq.efi`: GRUB, under the GPL version 3 or later. `of-grubbuild.sh`
  builds it from Debian's `grub-efi-ia32-bin`, whose source Debian publishes.
- The `openframe-crystalhd` package's library and firmware, which `crystalhd/build.sh` fetches rather
  than this repository holding: see `crystalhd/copyright`.
