#!/bin/bash
# Copyright of some portions of this project are held by (c) 2012 Tom Wambold.
# All other copyright for this project are held by (c) 2021 Jaume Zaragoza.
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy of
# this software and associated documentation files (the "Software"), to deal in
# the Software without restriction, including without limitation the rights to
# use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
# of the Software, and to permit persons to whom the Software is furnished to do
# so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

## CONFIGURE THESE VARIABLES
## ALSO LOOK AT THE install_packages FUNCTION TO SEE WHAT IS ACTUALLY INSTALLED

# Drive to install to.
DRIVE='/dev/sda'

# If the driva is SSD
SSD='TRUE'

# Device name for LUKS partition (must be lowercased)
LUKS_NAME='crypto'

# Root logical volume size
ROOT_SIZE="60G"

# BTRFS mount options
#TODO discard=async to enable TRIM?
MOUNT_OPTS="noatime,nodiratime,compress=lzo"
if [ "$SSD" == "TRUE" ]; then
    MOUNT_OPTS="$MOUNT_OPTS,ssd"
fi

# Hostname of the installed machine.
HOSTNAME='host100'

# Encrypt everything (except /boot).  ALWAYS ENABLED
#ENCRYPT_DRIVE='TRUE'

# Main user to create (by default, added to wheel group, and others).
USER_NAME='user'

# System timezone.
TIMEZONE='Europe/Madrid'

# Have /tmp on a tmpfs or not.  Leave blank to disable.
# Only leave this blank on systems with very little RAM.
TMP_ON_TMPFS='TRUE'

# System locale and keymap
LOCALE='ca_ES.UTF-8'
KEYMAP='es'

# Choose your video driver
# For Intel
VIDEO_DRIVER="i915"
# For nVidia
#VIDEO_DRIVER="nouveau"
# For ATI
#VIDEO_DRIVER="radeon"
# For generic stuff
#VIDEO_DRIVER="vesa"

# Wireless device, leave blank to not use wireless and use DHCP instead.
NETWORK_DEVICE="wlan0"

# List of kernels to install
KERNELS="linux"

setup() {
    local efi_dev="$DRIVE"1
    local crypt_dev="$DRIVE"2

    echo 'Creating partitions'
    partition_drive "$DRIVE"

    local luks_part="/dev/mapper/$LUKS_NAME"

    echo 'Encrypting partition'
    encrypt_drive "$crypt_dev" $LUKS_NAME

    # echo 'Setting up LVM'
    # setup_lvm "$luks_part" vg00

    echo 'Formatting filesystems'
    format_filesystems "$efi_dev" "$luks_part" "$LUKS_NAME"

    echo 'Mounting filesystems'
    mount_filesystems "$efi_dev" "$luks_part" "$LUKS_NAME"

    echo 'Installing base system'
    install_base

    echo 'Setting fstab'
    set_fstab "$TMP_ON_TMPFS" "$efi_dev"

    echo 'Chrooting into installed system to continue setup...'
    cp $0 /mnt/setup.sh
    arch-chroot /mnt ./setup.sh chroot

    if [ -f /mnt/setup.sh ]
    then
        echo 'ERROR: Something failed inside the chroot, not unmounting filesystems so you can investigate.'
        echo 'Make sure you unmount everything before you try to run this script again.'
    else
        echo 'Unmounting filesystems'
        unmount_filesystems
        echo 'Done! Reboot system.'
    fi
}

configure() {
    local efi_dev="$DRIVE"1
    local crypt_dev="$DRIVE"2

    echo 'Setting hostname'
    set_hostname "$HOSTNAME"

    echo 'Setting timezone'
    set_timezone "$TIMEZONE"

    echo 'Setting locale'
    set_locale

    echo 'Setting console keymap'
    set_keymap

    echo 'Setting hosts file'
    set_hosts "$HOSTNAME"

    echo 'Configuring initial ramdisk'
    set_initcpio $crypt_dev

    echo 'Configuring bootloader'
    set_grub "$crypt_dev"

    echo 'Configuring sudo'
    set_sudoers

    echo 'Setting root password'
    set_root_password

    echo 'Creating initial user'
    create_user "$USER_NAME"

    echo 'Installing yay and powerpill'
    install_yay

    echo 'Installing additional packages'
    install_packages

    echo 'Clearing package tarballs'
    clean_packages

    echo 'Configuring network'
    set_network

    echo 'Setting initial daemons'
    set_daemons "$TMP_ON_TMPFS"

    echo 'Setting initial modules to load'
    set_modules_load

    echo 'Building locate database'
    update_locate

    rm /setup.sh
}

partition_drive() {
    local dev="$1"; shift

    # 300 MB ESP partition, everything else under encrypted BTRFS
    parted -s "$dev" \
        mklabel gpt \
        mkpart ESP fat32 1 300M \
        mkpart System 300M 100% \
        set 1 esp on \
        set 1 bios_grub on
}

encrypt_drive() {
    local dev="$1"; shift
    local name="$1"; shift

    # Encrypt drive with LUKS1, GRUB still doesn't support LUKS2
    #TODO switch to LUKS2 when suport comes to GRUB
    cryptsetup -y --type luks1 luksFormat "$dev"
    cryptsetup luksOpen "$dev" $name
}

setup_lvm() {
    local partition="$1"; shift
    local volgroup="$1"; shift

    pvcreate "$partition"
    vgcreate "$volgroup" "$partition"

    # Create a 1GB swap partition
    #lvcreate -C y -L1G "$volgroup" -n swap

    # Use configured size for root partition
    lvcreate -L $ROOT_SIZE "$volgroup" -n root

    # Use the rest for home partition
    lvcreate -l '+100%FREE' "$volgroup" -n home

    # Enable the new volumes
    vgchange -ay
}

format_filesystems() {
    local efi_dev="$1"; shift
    local luks_part="$1"; shift
    local label="$1"; shift

    mkfs.fat -F32 "$efi_dev"
    mkfs.btrfs -L $label $luks_part

    # Create subvolumes: root, snapshots, home anv /var/logs
    mount -o $MOUNT_OPTS $luks_part /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@snapshots
    btrfs subvolume create /mnt/@home
    # btrfs subvolume create /mnt/@var_log

    umount /mnt

    # Mount subvolumes and create nested subvolumes
    mount -o $MOUNT_OPTS,subvol=@ $luks_part /mnt
    mkdir /mnt/home
    mount -o $MOUNT_OPTS,subvol=@home $luks_part /mnt/home
    mkdir /mnt/.snapshots
    mount -o $MOUNT_OPTS,subvol=@snapshots $luks_part /mnt/.snapshots
    mkdir /mnt/var
    mkdir /mnt/var/cache
    mkdir /mnt/var/cache/pacman
    btrfs subvolume create /mnt/var/cache/pacman/mnt

    umount -R /mnt
}

mount_filesystems() {
    local esp="$1"; shift
    local luks_part="$1"; shift

    mount -o $MOUNT_OPTS,subvol=@ $luks_part /mnt
    mkdir /mnt/efi
    mount "$esp" /mnt/efi
    mount -o $MOUNT_OPTS,subvol=@home $luks_part /mnt/home
    mount -o $MOUNT_OPTS,subvol=@snapshots $luks_part /mnt/.snapshots
}

install_base() {
    echo 'Server = http://mirrors.kernel.org/archlinux/$repo/os/$arch' >> /etc/pacman.d/mirrorlist

    pacstrap /mnt base base-devel git btrfs-progs grub sudo $KERNELS
}

unmount_filesystems() {
    umount -R /mnt
    # swapoff /dev/vg00/swap
    # vgchange -an
    cryptsetup luksClose $LUKS_NAME
}

install_packages() {
    local packages=''

    # General utilities/libraries
    packages+=' alsa-utils python rfkill rsync unrar unzip zip pigz wget curl screen tmux systemd-sysvcompat fish'

    # Network
    packages+=' dnscrypt-proxy syncthing bind iwd openssh'

    # Filesystems
    packages+=' parted dosfstools ntfsprogs exfat-utils'

    # Misc programs
    packages+=' vlc hunspell-en_US hunspell-es_any hunspell-ca'

    # On Intel processors
    #TODO review microcode stuff
    packages+=' intel-ucode'

    # Graphics drivers
    #TODO review graphics stuff
    if [ "$VIDEO_DRIVER" = "i915" ]
    then
        packages+=' xf86-video-intel libva-intel-driver'
    elif [ "$VIDEO_DRIVER" = "nouveau" ]
    then
        packages+=' xf86-video-nouveau'
    elif [ "$VIDEO_DRIVER" = "radeon" ]
    then
        packages+=' xf86-video-ati'
    elif [ "$VIDEO_DRIVER" = "vesa" ]
    then
        packages+=' xf86-video-vesa'
    fi

    yay -Sy --noconfirm $packages
}

install_yay() {
    su $USER
    cd /tmp
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg -si --noconfirm

    cd /
    rm -rf /tmp/yay

    yay -S --noconfirm powerpill

    exit
}

clean_packages() {
    yes | pacman -Scc
}

update_pkgfile() {
    pkgfile -u
}

set_hostname() {
    local hostname="$1"; shift

    echo "$hostname" > /etc/hostname
}

set_timezone() {
    local timezone="$1"; shift

    ln -sT "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
}

set_locale() {
    echo "LANG=\"$LOCALE\"" >> /etc/locale.conf
    echo 'LC_COLLATE="C"' >> /etc/locale.conf
    echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
    echo "$LOCALE UTF-8" >> /etc/locale.gen
    locale-gen
}

set_keymap() {
    echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
}

set_hosts() {
    local hostname="$1"; shift

    cat > /etc/hosts <<EOF
127.0.0.1 localhost.localdomain localhost $hostname
::1       localhost.localdomain localhost $hostname
EOF
}

set_fstab() {
    # Try genfstab
    genfstab -U /mnt >> /mnt/etc/fstab
}

set_modules_load() {
    echo 'microcode' > /etc/modules-load.d/intel-ucode.conf
}

set_initcpio() {
    local crypt_dev="$1"; shift
    local keyfile="crypto_keyfile.bin"

    # Generate keyfile for unlocking ecrypted drive
    echo Generating keyfile
    dd bs=512 count=4 if=/dev/random of=/$keyfile iflag=fullblock
    chmod 600 /$keyfile
    chmod 600 /boot/initramfs-linux*
    echo Adding keyfile to LUKS header...
    cryptsetup luksAddkey $crypt_dev /$keyfile

    # Configure mkinitcpio
    sed -i 's/^MODULES=.*/MODULES=(btrfs)' /etc/mkinitcpio.conf
    sed -i "s/^FILES=.*/FILES=(\/$keyfile)" /etc/mkinitcpio.conf
    sed -i "s/^BINARIES=.*/BINARIES=(\/usr\/bin\/btrfs)" /etc/mkinitcpio.conf
    sed -i "s/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt keyboard resume fsck)" /etc/mkinitcpio.conf

    for kernel in $KERNELS; do
        mkinitcpio -p $kernel
    done
}

set_daemons() {
    local tmp_on_tmpfs="$1"; shift

    systemctl enable ntpd.service

    if [ -z "$tmp_on_tmpfs" ]
    then
        systemctl mask tmp.mount
    fi
}

set_grub() {
    local crypt_dev="$1"; shift
    local crypt_uuid=$(get_uuid "$crypt_dev")
    if [ "$SSD" == "TRUE" ]; then
        DISCARDS=":allow-discards"
    else
        DISCARDS=""
    fi

    grub-install --target=i386-pc $DRIVE

    sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet cryptdevice=UUID=$crypt_uuid:$LUKS_NAME$DISCARDS\"/"
    sed -i 's/^#GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/'
    sed -i 's/^GRUB_PRELOAD_MODULES=.*/GRUB_PRELOAD_MODULES="part_gpt"/'

    grub-mkconfig -o /boot/grub/grub.cfg
}

set_sudoers() {
    sed -i "s/^#%wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/" /etc/sudoers
    echo "Defaults insults" >> /etc/sudoers
}

set_network() {
    if [ "$NETWORK_DEVICE" =~ "wl" ]; then
        systemctl enable iwd

        # echo 'Enter the network SSID:'
        # read -l ssid

        # iwctl station $NETWORK_DEVICE conncet $ssid
    else
        systemctl enable dhcpcd@$NETWORK_DEVICE.service
    fi
}

set_root_password() {
    passwd
}

create_user() {
    local name="$1"; shift

    useradd -m -s /bin/zsh -G adm,systemd-journal,wheel,rfkill,games,network,video,audio,optical,floppy,storage,scanner,power,adbusers,wireshark "$name"
    passwd "$name"
}

update_locate() {
    updatedb
}

get_uuid() {
    lsblk -dno UUID $1
}

set -ex

if [ "$1" == "chroot" ]
then
    configure
else
    setup
fi
