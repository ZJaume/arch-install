#!/bin/bash
# Copyright (c) 2012 Tom Wambold
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# This script will set up an Arch installation with a 100 MB /boot partition
# and an encrypted LVM partition with swap and / inside.  It also installs
# and configures systemd as the init system (removing sysvinit).
#
# You should read through this script before running it in case you want to
# make any modifications, in particular, the variables just below, and the
# following functions:
#
#    partition_drive - Customize to change partition sizes (/boot vs LVM)
#    setup_lvm - Customize for partitions inside LVM
#    install_packages - Customize packages installed in base system
#                       (desktop environment, etc.)
#    install_aur_packages - More packages after packer (AUR helper) is
#                           installed
#    set_netcfg - Preload netcfg profiles
#
# https://wiki.archlinux.org/index.php/Dm-crypt/Encrypting_an_entire_system#Btrfs_subvolumes_with_swap
# https://www.mayrhofer.eu.org/post/ssd-linux-benchmark/

## CONFIGURE THESE VARIABLES
## ALSO LOOK AT THE install_packages FUNCTION TO SEE WHAT IS ACTUALLY INSTALLED

# Drive to install to.
DRIVE='/dev/sda'

# Device name for LUKS partition (must be lowercased)
LUKS_NAME='crypto'

# Root logical volume size
ROOT_SIZE="60G"

# BTRFS mount options
#TODO discard=async to enable TRIM?
MOUNT_OPTS="noatime,nodiratime,ssd,compress=lzo"

# Hostname of the installed machine.
HOSTNAME='host100'

# Encrypt everything (except /boot).  ALWAYS ENABLED
#ENCRYPT_DRIVE='TRUE'

# Passphrase used to encrypt the drive (leave blank to be prompted).
DRIVE_PASSPHRASE=''

# Root password (leave blank to be prompted).
ROOT_PASSWORD=''

# Main user to create (by default, added to wheel group, and others).
USER_NAME='user'

# The main user's password (leave blank to be prompted).
USER_PASSWORD=''

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
WIRELESS_DEVICE="wlan0"
# For tc4200's
#WIRELESS_DEVICE="eth1"

setup() {
    local efi_dev="$DRIVE"1
    local crypt_dev="$DRIVE"2

    echo 'Creating partitions'
    partition_drive "$DRIVE"

    local luks_part="/dev/mapper/$LUKS_NAME"

    if [ -z "$DRIVE_PASSPHRASE" ]
    then
        echo 'Enter a passphrase to encrypt the disk:'
        stty -echo
        read DRIVE_PASSPHRASE
        stty echo
    fi

    echo 'Encrypting partition'
    encrypt_drive "$crypt_dev" "$DRIVE_PASSPHRASE" $LUKS_NAME

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

    echo 'Installing additional packages'
    install_packages

    echo 'Installing packer'
    # install_packer

    echo 'Installing AUR packages'
    # install_aur_packages

    echo 'Clearing package tarballs'
    clean_packages

    echo 'Updating pkgfile database'
    update_pkgfile

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

    echo 'Setting initial modules to load'
    set_modules_load

    echo 'Configuring initial ramdisk'
    set_initcpio $crypt_dev

    echo 'Setting initial daemons'
    set_daemons "$TMP_ON_TMPFS"

    echo 'Configuring bootloader'
    set_syslinux "$crypt_dev"

    echo 'Configuring sudo'
    set_sudoers

    echo 'Configuring slim'
    set_slim

    if [ -n "$WIRELESS_DEVICE" ]
    then
        echo 'Configuring netcfg'
        set_netcfg
    fi

    if [ -z "$ROOT_PASSWORD" ]
    then
        echo 'Enter the root password:'
        stty -echo
        read ROOT_PASSWORD
        stty echo
    fi
    echo 'Setting root password'
    set_root_password "$ROOT_PASSWORD"

    if [ -z "$USER_PASSWORD" ]
    then
        echo "Enter the password for user $USER_NAME"
        stty -echo
        read USER_PASSWORD
        stty echo
    fi
    echo 'Creating initial user'
    create_user "$USER_NAME" "$USER_PASSWORD"

    echo 'Building locate database'
    update_locate

    rm /setup.sh
}

partition_drive() {
    local dev="$1"; shift

    # 300 MB ESP partition, everything else under encrypted BTRFS
    parted -s "$dev" \
        mklabel gpt \
        mkpart "EFI system partition" fat32 1 300M \
        mkpart "Encrypted system partition" 300M 100% \
        set 1 esp on
}

encrypt_drive() {
    local dev="$1"; shift
    local passphrase="$1"; shift
    local name="$1"; shift

    # Encrypt drive with LUKS1, GRUB still doesn't support LUKS2
    #TODO switch to LUKS2 when suport comes to GRUB
    echo -en "$passphrase" | cryptsetup -y --type luks1 luksFormat "$dev"
    echo -en "$passphrase" | cryptsetup luksOpen "$dev" $name
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
    mount -o $MOUNT_OPTS,subvol=@home $luks_part /mnt/home
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

    pacstrap /mnt base base-devel btrfs-progs
    pacstrap /mnt syslinux
}

unmount_filesystems() {
    umount /mnt/boot
    umount /mnt
    swapoff /dev/vg00/swap
    vgchange -an
    if [ -n "$ENCRYPT_DRIVE" ]
    then
        cryptsetup luksClose lvm
    fi
}

install_packages() {
    local packages=''

    # General utilities/libraries
    packages+=' alsa-utils aspell-en chromium cpupower gvim mlocate net-tools ntp openssh p7zip pkgfile powertop python python2 rfkill rsync sudo unrar unzip wget zip systemd-sysvcompat zsh grml-zsh-config'

    # Development packages
    packages+=' apache-ant cmake gdb git maven mercurial subversion tcpdump valgrind wireshark-gtk'

    # Netcfg
    if [ -n "$WIRELESS_DEVICE" ]
    then
        packages+=' netcfg ifplugd dialog wireless_tools wpa_actiond wpa_supplicant'
    fi

    # Java stuff
    packages+=' icedtea-web-java7 jdk7-openjdk jre7-openjdk'

    # Libreoffice
    packages+=' libreoffice-calc libreoffice-en-US libreoffice-gnome libreoffice-impress libreoffice-writer hunspell-en hyphen-en mythes-en'

    # Misc programs
    packages+=' mplayer pidgin vlc xscreensaver gparted dosfstools ntfsprogs'

    # Xserver
    packages+=' xorg-apps xorg-server xorg-xinit xterm'

    # Slim login manager
    packages+=' slim archlinux-themes-slim'

    # Fonts
    packages+=' ttf-dejavu ttf-liberation'

    # On Intel processors
    packages+=' intel-ucode'

    # For laptops
    packages+=' xf86-input-synaptics'

    # Extra packages for tc4200 tablet
    #packages+=' ipw2200-fw xf86-input-wacom'

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

    pacman -Sy --noconfirm $packages
}

install_packer() {
    mkdir /foo
    cd /foo
    curl https://aur.archlinux.org/packages/pa/packer/packer.tar.gz | tar xzf -
    cd packer
    makepkg -si --noconfirm --asroot

    cd /
    rm -rf /foo
}

install_aur_packages() {
    mkdir /foo
    export TMPDIR=/foo
    packer -S --noconfirm android-udev
    packer -S --noconfirm chromium-pepper-flash-stable
    packer -S --noconfirm chromium-libpdf-stable
    unset TMPDIR
    rm -rf /foo
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

    mkinitcpio -p linux
}

set_daemons() {
    local tmp_on_tmpfs="$1"; shift

    systemctl enable cronie.service cpupower.service ntpd.service slim.service

    if [ -n "$WIRELESS_DEVICE" ]
    then
        systemctl enable net-auto-wired.service net-auto-wireless.service
    else
        systemctl enable dhcpcd@eth0.service
    fi

    if [ -z "$tmp_on_tmpfs" ]
    then
        systemctl mask tmp.mount
    fi
}

set_syslinux() {
    #TODO change to GRUB
    local crypt_dev="$1"; shift

    local lvm_uuid=$(get_uuid "$crypt_dev")

    local crypt=""
    if [ -n "$ENCRYPT_DRIVE" ]
    then
        # Load in resources
        crypt="cryptdevice=/dev/disk/by-uuid/$lvm_uuid:lvm"
    fi

    cat > /boot/syslinux/syslinux.cfg <<EOF
# Config file for Syslinux -
# /boot/syslinux/syslinux.cfg
#
# Comboot modules:
#   * menu.c32 - provides a text menu
#   * vesamenu.c32 - provides a graphical menu
#   * chain.c32 - chainload MBRs, partition boot sectors, Windows bootloaders
#   * hdt.c32 - hardware detection tool
#   * reboot.c32 - reboots the system
#   * poweroff.com - shutdown the system
#
# To Use: Copy the respective files from /usr/lib/syslinux to /boot/syslinux.
# If /usr and /boot are on the same file system, symlink the files instead
# of copying them.
#
# If you do not use a menu, a 'boot:' prompt will be shown and the system
# will boot automatically after 5 seconds.
#
# Please review the wiki: https://wiki.archlinux.org/index.php/Syslinux
# The wiki provides further configuration examples

DEFAULT arch
PROMPT 0        # Set to 1 if you always want to display the boot: prompt 
TIMEOUT 50
# You can create syslinux keymaps with the keytab-lilo tool
#KBDMAP de.ktl

# Menu Configuration
# Either menu.c32 or vesamenu32.c32 must be copied to /boot/syslinux 
UI menu.c32
#UI vesamenu.c32

# Refer to http://syslinux.zytor.com/wiki/index.php/Doc/menu
MENU TITLE Arch Linux
#MENU BACKGROUND splash.png
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std
MENU COLOR help         37;40   #c0ffffff #a0000000 std
MENU COLOR timeout_msg  37;40   #80ffffff #00000000 std
MENU COLOR timeout      1;37;40 #c0ffffff #00000000 std
MENU COLOR msg07        37;40   #90ffffff #a0000000 std
MENU COLOR tabmsg       31;40   #30ffffff #00000000 std

# boot sections follow
#
# TIP: If you want a 1024x768 framebuffer, add "vga=773" to your kernel line.
#
#-*

LABEL arch
	MENU LABEL Arch Linux
	LINUX ../vmlinuz-linux
	APPEND root=/dev/vg00/root ro $crypt resume=/dev/vg00/swap quiet
	INITRD ../initramfs-linux.img

LABEL archfallback
	MENU LABEL Arch Linux Fallback
	LINUX ../vmlinuz-linux
	APPEND root=/dev/vg00/root ro $crypt resume=/dev/vg00/swap
	INITRD ../initramfs-linux-fallback.img

LABEL hdt
        MENU LABEL HDT (Hardware Detection Tool)
        COM32 hdt.c32

LABEL reboot
        MENU LABEL Reboot
        COM32 reboot.c32

LABEL off
        MENU LABEL Power Off
        COMBOOT poweroff.com
EOF

    syslinux-install_update -iam
}

set_sudoers() {
    cat > /etc/sudoers <<EOF
## sudoers file.
##
## This file MUST be edited with the 'visudo' command as root.
## Failure to use 'visudo' may result in syntax or file permission errors
## that prevent sudo from running.
##
## See the sudoers man page for the details on how to write a sudoers file.
##

##
## Host alias specification
##
## Groups of machines. These may include host names (optionally with wildcards),
## IP addresses, network numbers or netgroups.
# Host_Alias	WEBSERVERS = www1, www2, www3

##
## User alias specification
##
## Groups of users.  These may consist of user names, uids, Unix groups,
## or netgroups.
# User_Alias	ADMINS = millert, dowdy, mikef

##
## Cmnd alias specification
##
## Groups of commands.  Often used to group related commands together.
# Cmnd_Alias	PROCESSES = /usr/bin/nice, /bin/kill, /usr/bin/renice, \
# 			    /usr/bin/pkill, /usr/bin/top

##
## Defaults specification
##
## You may wish to keep some of the following environment variables
## when running commands via sudo.
##
## Locale settings
# Defaults env_keep += "LANG LANGUAGE LINGUAS LC_* _XKB_CHARSET"
##
## Run X applications through sudo; HOME is used to find the
## .Xauthority file.  Note that other programs use HOME to find   
## configuration files and this may lead to privilege escalation!
# Defaults env_keep += "HOME"
##
## X11 resource path settings
# Defaults env_keep += "XAPPLRESDIR XFILESEARCHPATH XUSERFILESEARCHPATH"
##
## Desktop path settings
# Defaults env_keep += "QTDIR KDEDIR"
##
## Allow sudo-run commands to inherit the callers' ConsoleKit session
# Defaults env_keep += "XDG_SESSION_COOKIE"
##
## Uncomment to enable special input methods.  Care should be taken as
## this may allow users to subvert the command being run via sudo.
# Defaults env_keep += "XMODIFIERS GTK_IM_MODULE QT_IM_MODULE QT_IM_SWITCHER"
##
## Uncomment to enable logging of a command's output, except for
## sudoreplay and reboot.  Use sudoreplay to play back logged sessions.
# Defaults log_output
# Defaults!/usr/bin/sudoreplay !log_output
# Defaults!/usr/local/bin/sudoreplay !log_output
# Defaults!/sbin/reboot !log_output

##
## Runas alias specification
##

##
## User privilege specification
##
root ALL=(ALL) ALL

## Uncomment to allow members of group wheel to execute any command
%wheel ALL=(ALL) ALL

## Same thing without a password
# %wheel ALL=(ALL) NOPASSWD: ALL

## Uncomment to allow members of group sudo to execute any command
# %sudo ALL=(ALL) ALL

## Uncomment to allow any user to run sudo if they know the password
## of the user they are running the command as (root by default).
# Defaults targetpw  # Ask for the password of the target user
# ALL ALL=(ALL) ALL  # WARNING: only use this together with 'Defaults targetpw'

%rfkill ALL=(ALL) NOPASSWD: /usr/sbin/rfkill
%network ALL=(ALL) NOPASSWD: /usr/bin/netcfg, /usr/bin/wifi-menu

## Read drop-in files from /etc/sudoers.d
## (the '#' here does not indicate a comment)
#includedir /etc/sudoers.d
EOF

    chmod 440 /etc/sudoers
}

set_slim() {
    cat > /etc/slim.conf <<EOF
# Path, X server and arguments (if needed)
# Note: -xauth $authfile is automatically appended
default_path        /bin:/usr/bin:/usr/local/bin
default_xserver     /usr/bin/X
xserver_arguments -nolisten tcp vt07

# Commands for halt, login, etc.
halt_cmd            /sbin/poweroff
reboot_cmd          /sbin/reboot
console_cmd         /usr/bin/xterm -C -fg white -bg black +sb -T "Console login" -e /bin/sh -c "/bin/cat /etc/issue; exec /bin/login"
suspend_cmd         /usr/bin/systemctl hybrid-sleep

# Full path to the xauth binary
xauth_path         /usr/bin/xauth 

# Xauth file for server
authfile           /var/run/slim.auth

# Activate numlock when slim starts. Valid values: on|off
# numlock             on

# Hide the mouse cursor (note: does not work with some WMs).
# Valid values: true|false
# hidecursor          false

# This command is executed after a succesful login.
# you can place the %session and %theme variables
# to handle launching of specific commands in .xinitrc
# depending of chosen session and slim theme
#
# NOTE: if your system does not have bash you need
# to adjust the command according to your preferred shell,
# i.e. for freebsd use:
# login_cmd           exec /bin/sh - ~/.xinitrc %session
# login_cmd           exec /bin/bash -login ~/.xinitrc %session
login_cmd           exec /bin/zsh -l ~/.xinitrc %session

# Commands executed when starting and exiting a session.
# They can be used for registering a X11 session with
# sessreg. You can use the %user variable
#
# sessionstart_cmd	some command
# sessionstop_cmd	some command

# Start in daemon mode. Valid values: yes | no
# Note that this can be overriden by the command line
# options "-d" and "-nodaemon"
# daemon	yes

# Available sessions (first one is the default).
# The current chosen session name is replaced in the login_cmd
# above, so your login command can handle different sessions.
# see the xinitrc.sample file shipped with slim sources
sessions            foo

# Executed when pressing F11 (requires imagemagick)
#screenshot_cmd      import -window root /slim.png

# welcome message. Available variables: %host, %domain
welcome_msg         %host

# Session message. Prepended to the session name when pressing F1
# session_msg         Session: 

# shutdown / reboot messages
shutdown_msg       The system is shutting down...
reboot_msg         The system is rebooting...

# default user, leave blank or remove this line
# for avoid pre-loading the username.
#default_user        simone

# Focus the password field on start when default_user is set
# Set to "yes" to enable this feature
#focus_password      no

# Automatically login the default user (without entering
# the password. Set to "yes" to enable this feature
#auto_login          no

# current theme, use comma separated list to specify a set to 
# randomly choose from
#current_theme       default
current_theme       archlinux-simplyblack

# Lock file
lockfile            /run/lock/slim.lock

# Log file
logfile             /var/log/slim.log
EOF
}

set_netcfg() {
    cat > /etc/network.d/wired <<EOF
CONNECTION='ethernet'
DESCRIPTION='Ethernet with DHCP'
INTERFACE='eth0'
IP='dhcp'
EOF

    chmod 600 /etc/network.d/wired

    cat > /etc/conf.d/netcfg <<EOF
# Enable these netcfg profiles at boot time.
#   - prefix an entry with a '@' to background its startup
#   - set to 'last' to restore the profiles running at the last shutdown
#   - set to 'menu' to present a menu (requires the dialog package)
# Network profiles are found in /etc/network.d
NETWORKS=()

# Specify the name of your wired interface for net-auto-wired
WIRED_INTERFACE="eth0"

# Specify the name of your wireless interface for net-auto-wireless
WIRELESS_INTERFACE="$WIRELESS_DEVICE"

# Array of profiles that may be started by net-auto-wireless.
# When not specified, all wireless profiles are considered.
#AUTO_PROFILES=("profile1" "profile2")
EOF
}

set_root_password() {
    local password="$1"; shift

    echo -en "$password\n$password" | passwd
}

create_user() {
    local name="$1"; shift
    local password="$1"; shift

    useradd -m -s /bin/zsh -G adm,systemd-journal,wheel,rfkill,games,network,video,audio,optical,floppy,storage,scanner,power,adbusers,wireshark "$name"
    echo -en "$password\n$password" | passwd "$name"
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
