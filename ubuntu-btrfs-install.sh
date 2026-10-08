#!/bin/bash
# Author: Diogo Pessoa (https://github.com/diogopessoa)
# License: MIT
# Description: Configure Ubuntu with Btrfs subvolumes and fstab entries.
#              Installation of Snapper and Btrfs Assistant should be done after reboot.

set -e

script=$(readlink -f "$0")
scriptname=$(basename "$script")
[ $(id -u) -eq 0 ] || { echo "ERRO: This script must be run as root."; exit 1; }

mp=/mnt/root

# Subvolumes and their mount points (@ for / is handled separately)
subvols=(
    @home:/home
    @log:/var/log
    @cache:/var/cache
    @libvirt:/var/lib/libvirt
    @flatpak:/var/lib/flatpak
    @docker:/var/lib/docker
    @containers:/var/lib/containers
    @machines:/var/lib/machines
    @var_tmp:/var/tmp
    @opt:/opt
)

show_help() {
    echo "Create Btrfs subvolumes and adjust fstab."
    echo "Usage: $scriptname {root-dev} {boot-dev} [{efi-dev}]"
    exit 1
}

if [ $# -lt 2 ]; then
    show_help
fi

rootdev="$1"
bootdev="$2"
efidev="$3"

efi=false
[ -n "$efidev" ] && efi=true

preparation() {
    echo "--- Preparing the environment ---"
    umount /target/boot/efi 2>/dev/null || true
    umount /target/boot 2>/dev/null || true
    umount /target 2>/dev/null || true
    mkdir -p "$mp"
}

create_subvols() {
    echo "--- Creating Btrfs Subvolumes ---"
    mount /dev/"$rootdev" "$mp"
    cd "$mp"

    btrfs subvolume snapshot . @

    find -maxdepth 1 \! -name "@*" \! -name . -exec rm -Rf {} \;

    for entry in "${subvols[@]}"; do
        subvol=${entry%%:*}
        mountdir=@${entry#*:}

        btrfs subvolume create "$subvol"

        if [ -d "$mountdir" ]; then
            # Keep the original owner and mode (/var/tmp is 1777, /var/log is root:syslog 0775)
            chown --reference="$mountdir" "$subvol"
            chmod --reference="$mountdir" "$subvol"
            # Move the installed data, hidden files included, into the subvolume.
            # The emptied directory stays in @ as the mount point.
            find "$mountdir" -mindepth 1 -maxdepth 1 -exec mv -t "$subvol" {} +
        else
            mkdir -p "$mountdir"
        fi
    done

    cd /
    umount "$mp"
    mount /dev/"$rootdev" -o subvol=@ "$mp"
}

ajusta_fstab() {
    echo "--- Adjusting /etc/fstab ---"
    root_uuid=$(blkid --output export /dev/"$rootdev" | grep ^UUID=)
    fstab_path="$mp/etc/fstab"

    # The installer's swap file (/swap.img) is now inside @, and btrfs refuses
    # to snapshot a subvolume holding an active swap file: remove it.
    # Swap partitions are kept.
    awk '$3 == "swap" && $1 ~ /^\// && $1 !~ /^\/dev\// { print $1 }' "$fstab_path" |
        while read -r swapfile; do rm -f "$mp$swapfile"; done

    # Drop the installer entries rewritten below. Match on fields, not on
    # spaces: the installer separates the swap line with tabs.
    awk '
        /^[ \t]*#/ { print; next }
        $3 == "btrfs" || $2 == "/boot" || $2 == "/boot/efi" { next }
        $3 == "swap" && $1 ~ /^\// && $1 !~ /^\/dev\// { next }
        { print }
    ' "$fstab_path" > "$fstab_path.new"
    mv "$fstab_path.new" "$fstab_path"

    opts="defaults,ssd,discard=async,noatime,space_cache=v2,compress=zstd:1"
    echo "$root_uuid / btrfs $opts,subvol=@ 0 0" >> "$fstab_path"
    for entry in "${subvols[@]}"; do
        echo "$root_uuid ${entry#*:} btrfs $opts,subvol=${entry%%:*} 0 0" >> "$fstab_path"
    done

    boot_uuid=$(blkid --output export /dev/"$bootdev" | grep ^UUID=)
    echo "$boot_uuid /boot ext4 defaults 0 2" >> "$fstab_path"

    if [ "$efi" = true ]; then
        efi_uuid=$(blkid --output export /dev/"$efidev" | grep ^UUID=)
        echo "$efi_uuid /boot/efi vfat umask=0077 0 1" >> "$fstab_path"
    fi
}

chroot_and_update() {
    echo "--- Environment chroot ---"
    for dir in proc sys dev run; do
        mount --bind /$dir "$mp"/$dir
    done
    mount /dev/"$bootdev" "$mp"/boot
    $efi && mount /dev/"$efidev" "$mp"/boot/efi

    chroot "$mp" update-grub
    chroot "$mp" update-initramfs -u
}

unmount_everything() {
    echo "--- Unmounting partitions ---"
    for dir in proc sys dev run; do
        umount "$mp"/$dir 2>/dev/null || true
    done
    $efi && umount "$mp"/boot/efi 2>/dev/null || true
    umount "$mp"/boot 2>/dev/null || true
    umount "$mp" 2>/dev/null || true
}

# Execucao
preparation
create_subvols
ajusta_fstab
chroot_and_update
unmount_everything

echo "✅ Script completed successfully!"
echo "🔁 Reboot before installing Snapper and Btrfs Assistant."
