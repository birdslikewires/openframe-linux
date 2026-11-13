#!/bin/bash

## of-grubbuild.sh v26.11.2 (13th November 2026)
##  Builds grubq.efi, the OpenFrame's GRUB, for its 32-bit EFI, from Debian's
##  grub-efi-ia32-bin, on a Debian system with that package installed:
##      of-grubbuild.sh <output directory>
##  The result goes in overlay-*/usr/lib/openframe/grubq.efi, from where of-bootnsh
##  copies it to the boot volume when boot.nsh uses it. The kernel normally starts
##  directly from the firmware's shell; GRUB is the safety net for the internal memory
##  on firmware that can't load the kernel from there (see of-bootnsh).
##
##  It finds grub.cfg on the volume it was started from (prefix "/", device from the
##  firmware), whatever other disks the firmware found first, and prints nothing: the
##  firmware's text console never reaches the panel. A build that draws on the panel
##  itself (efi_gop and gfxterm) hangs on BirdsLikeWires firmware 26.11.29 before
##  drawing anything, with or without efi_uga, so there is no such build.

set -e
OUT=${1:?usage: $0 <output directory>}
MODDIR=/usr/lib/grub/i386-efi
[ -d "$MODDIR" ] || { echo "Needs grub-efi-ia32-bin (apt install grub-efi-ia32-bin)."; exit 1; }
mkdir -p "$OUT"

MODS="part_msdos part_gpt fat ext2 normal configfile linux echo test search search_fs_uuid search_label search_fs_file"
grub-mkimage -O i386-efi -d "$MODDIR" -p / -o "$OUT/grubq.efi" $MODS

echo "Built with $(grub-mkimage --version) ($(dpkg-query -W -f '${Version}' grub-efi-ia32-bin 2>/dev/null)):"
ls -l "$OUT/grubq.efi"
md5sum "$OUT/grubq.efi"
