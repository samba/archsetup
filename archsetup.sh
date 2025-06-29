#!/bin/bash
#
# ##############
# !!! WARNING !!!
#   DO NOT run this on any system whose data you care about.  It's highly destructive.
#   Also note, it might have some bugs still.
# ##############
#
# This deploys Arch linux using a sensible disk layout for laptops and desktop workstations.
#
# This script will wipe all non-hotpluggable storage, set up encryption (if configured) and LVM, and prepare a BTRFS host filesystem.
#
# Prerequisites
#   - Disconnect any storage devices which should not be erased during installation.
#   - If you want SecureBoot to work, activate setup mode in your BIOS __before__ performing this installation.
#
# There isn't much security to be gained in setting up encryption without using SecureBoot and the TPM.
# This script will set up encryption anyway, but the key will be baked into the initramfs.
# SecureBoot and TPM key enrollment will only occur if both are available and in setup mode during installation.
#
# Usage:
#   1.  Download this script to /tmp/archsetup.sh
#   2.  Execute: `bash archsetup.sh <options>` as described below
#   3.  Customize the system as you need... possibly requires `arch-chroot /mnt`
#   4.  Reboot
#
#
# (Recommend using option -x to correctly diagnose any errors...)
# bash -x archsetup.sh <options>
#
#   -N <full username>  e.g. "Bill Gates"
#   -U <username>       e.g. "billgates"
#   -H <hostname>       e.g. "billpc"
#   -E                  activate encryption
#   -K <passphrase>     e.g. "YourSuperSecretEncryptionKey"
#   -P <percentexpr>    e.g. "90%FREE" or "40%VG" -- as per `lvcreate` options
#   -L <language>       e.g. "en_US.UTF-8"
#   -R <regiontz>       e.g. "America/Los_Angeles"


set -euf -o pipefail

BOOT_EFI_SIZE="1024MiB"

get_swap_gb () {
    cat /proc/meminfo | grep MemTotal | awk '{ print $2, $3 }' | while read count unit; do
        case $unit in
            kB) count=$((count / 1024**2)) ;;
            mB) count=$((count / 1024));;
            gB) break ;;
        esac
    done
    echo $((count +1)) # round up for swap
}

find_isomount_device_major () {
    lsblk -s -o NAME,PKNAME,MAJ $(mount -l -t iso9600 | cut -f 1 -d ' ') | tail -n1 | awk '{print $3}'
}

find_target_disk () { # May yield multiple non-hotplug disks
    FIELDS=NAME,TYPE,HOTPLUG,SIZE,DISC-ZERO,ROTA
    exclude=$(find_isomount_device_major)
    (   lsblk -o ${FIELDS} -S -e ${exclude} -Py
        lsblk -o ${FIELDS} -N -e ${exclude} -Py
    ) | grep 'TYPE="disk"' | grep 'HOTPLUG="0"'
}


# Sets up one or more permanent disks, with encryption, replication, and BTRFS subvolumes
# Context: liveiso
do_disk_setup () {
    # generate crypto key
    case ${2:-no} in
        yes)
            dd if=/dev/urandom of=/tmp/luks.key bs=2064 count=1
        ;;
    esac

    EFI_DEV=()
    DEVICES=()
    ZEROES=0
    SSD=0
    count=0

    # set up partitions
    while read params; do
        eval ${params}

        count=$((count + 1))

        # make disk partitions
        sgdisk --clear \
            --new=1:0:+${BOOT_EFI_SIZE} --typecode=1:ef00 --change-name=1:EFI${count} \
            --new=2:0:0                 --typecode=2:8300 --change-name=2:system${count} \
            ${NAME} # from the params above

        EFI_DEV+=(/dev/disk/by-label/EFI${count})

        if [[ 1 -eq ${DISC_ZERO} ]]; then
            ZEROES=$(( ZEROES + 1 ))
        fi

        if [[ 0 -eq ${ROTA} ]] ; then
            SSD=$(( SSD + 1 ))
        fi

        case ${2:-no} in
            yes) # setup encryption
                # Create the encryption volume
                cryptsetup luksFormat -q  /dev/disk/by-label/system${count} /tmp/luks.key

                # If provided, also register the user's human-friendly key
                test -f "${3}" &&  cryptsetup luksAddKey -q --new-keyfile "${3}" -d /tmp/luks.key /dev/disk/by-label/system${count}

                # Mount the encrypted volume
                cryptsetup open  -d /tmp/luks.key /dev/disk/by-label/system${count} system${count}
                DEVICES+=(/dev/mapper/system${count})

                # Store the crypttab entry, as it may be needed in some init configurations.
                # NB: the key path here is relative to the root filesystem in the target, later after reboot
                dev_uuid=$(blkid -s UUID -o value /dev/disk/by-label/system${count})
                echo "system${count}  UUID=${dev_uuid}  /etc/luks.key" >> /tmp/crypttab.init
            ;;
            no)
                DEVICES+=(/dev/disk/by-label/system${count})
            ;;
        esac

    done < ${1}

    for dev in ${DEVICES[@]} ; do
        pvcreate ${dev}
    done

    if [[ ${#EFI_DEV} -gt 1 ]]; then  # set up RAID mirror for the EFI boot
        mdadm --create /dev/md0_efi --level 1 --raid-disks ${#EFI_DEV} --metadata 1.0 ${EFI_DEV[@]}
        mkfs.fat -F32 -N EFI /dev/md0_efi
        echo "/dev/md0_efi" > /tmp/efidev
    else
        mkfs.fat -F32 -N EFI ${EFI_DEV[0]}
        echo "${EFI_DEV[0]}" > /tmp/efidev
    fi

    vgcreate system ${DEVICES[@]}

    volopts=""
    if [[ ${#DEVICES} -eq 2 ]] ; then  # a RAID mirror is sensible
        volopts="--mirrors ${#DEVICES}"
    elif [[ ${#DEVICES} -gt 2 ]] ; then  # more disks, RAID5 is better
        volopts="--type raid5 -i ${#DEVICES}"
    fi

    # Create a "thick" swap volume, because it's useful for hibernate/resume
    lvcreate --size $(get_swap_gb)G ${volopts} -n swap system


    # Create thin volumes for everything else
    lvcreate ${volopts} --size 1G -n tmeta system
    lvcreate ${volopts} --extents "${4:-40%VG}"  tpool system
    lvconvert --thinpool system/tpool --poolmetadata system/tmeta

    # Create a single root volume for btrfs
    # This is a fixed size, assuming that the remaining space will be allocated later as the user sees fit
    lvcreate -T --thinpool system/tpool --virtualsize 100G -n root system

    mkfsopts="-O quota,fst,bgt,squota"
    mountopts="noatime,compress=lzo,defaults"
    if [[ ${ZEROES} -eq ${#DEVICES} ]]; then
        mountopts="${mountopts},discard"
    else
        mkfsopts="${mkfsopts} --nodiscard"
    fi

    if [[ ${SSD} -eq ${#DEVICES} ]]; then
        mountopts="${mountopts},ssd"
    fi

    mkswap -L swap /dev/system/swap
    mkfs.btrfs -L arch/root "${mkfsopts}" /dev/system/root

    mount -o ${mountopts} /dev/system/root /mnt

    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@root
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@var
    btrfs subvolume create /mnt/@log
    btrfs subvolume create /mnt/@cache
    btrfs subvolume create /mnt/@snap

    umount /mnt
    mount -o ${mountopts},subvol=@root /dev/system/root /mnt
    mount -o ${mountopts},subvol=@home /dev/system/root /mnt/home
    mount -o ${mountopts},subvol=@var /dev/system/root /mnt/var
    mount -o ${mountopts},subvol=@log /dev/system/root /mnt/var/log
    mount -o ${mountopts},subvol=@cache /dev/system/root /mnt/var/cache
    mount -o ${mountopts},subvol=@snap /dev/system/root /mnt/.snapshot

    swapon -a
    mount -o defaults,nosuid,nodev,relatime,fmask=0022,dmask=0022,codepage=437,shortname=mixed,errors=remount-ro  $(cat /tmp/efidev) /mnt/boot

    mkdir -p /mnt/etc

    test -f /tmp/luks.key && cp /tmp/luks.key /mnt/etc/luks.key
    test -f /tmp/crypttab.init && cp /tmp/crypttab.init /mnt/etc/crypttab.initramfs


    genfstab -U /mnt >> /mnt/etc/fstab
}

# Populates a few important files with nice defaults
# Context: liveiso
target_files () {
mkdir -p ${1}/etc/pacman.d/hooks

echo >> ${1}/etc/pacman.conf <<EOF
# Misc options
UseSyslog
Color
ILoveCandy
#NoProgressBar
CheckSpace
VerbosePkgLists
ParallelDownloads = 10
EOF

echo >${1}/etc/pacman.d/hooks/998-systemd-boot.hook  <<EOF
[Trigger]
Type = Package
Operation = Install
Operation = Upgrade
Target = systemd

[Action]
Description = Updating systemd-boot
When = PostTransaction
Exec = /usr/bin/bootctl update
EOF
}

# Bootstrap package installation
# Context: liveiso
do_package_setup () {
    CPUMODEL=NONE
    case "$(cat /proc/cpuinfo | grep vendor_id | awk '{print $3}')" in
        AuthenticAMD) CPUMODEL="amd" ;;
        GenuineIntel) CPUMODEL="intel" ;;
    esac

    reflector --save /etc/pacman.d/mirrorlist --protocol https --sort rate --latest 5


    MORE_PACKAGES=()

    lspci | grep Broadcom && MORE_PACKAGES+=(broadcom-wl-dkms)
    lspci | grep Nvidia && MORE_PACKAGES+=(nvidia-dkms)
    lspci | grep -i realtek && MORE_PACKAGES+=(r8168-lts)

    if [[ ${2} = "yes" ]] ; then
        MORE_PACKAGES+=(tpm2-tss tpm2-tools)
        MORE_PACKAGES+=(sbctl sbsigntools)
    fi


    # NB: this will also copy in the pacman config
    pacstrap ${1} base ${CPUMODEL}-ucode \
        linux-lts linux-firmware btrfs-progs lvm2 mdadm \
        efibootmgr grub grub-btrfs breeze-grub  \
        inotify-tools \
        exfatprogs \
        ethtool \
        cpupower acpi acpid \
        sudo htop btop \
        networkmanager iwd openssh \
        git vim zsh zsh-completions tmux \
        man man-pages man-db texinfo \
        ${MORE_PACKAGES[@]} --noconfirm

}

get_tpm_module_driver () {
    dmesg | grep -oE 'tpm_[a-z0-9]+'
}

# extract a few key values from the sbctl JSON status, rendered shell-compatible variables
secureboot_support_status () {
    sbctl status --json | sed 's/,/,\n/' | \
        grep -oE -e '"(installed|setup_mode|secure_boot)":\s*(true|false)' | \
        sed -E 's/:\s*/=/g; s/"//g;' | tr  '[:lower:]' '[:upper:]'
}

# return 0 when SB is supported & setup mode is active.
secureboot_setup_active () {
    eval $(secureboot_support_status)
    test "true" = "${SETUP_MODE}" -a "true" = "${SECURE_BOOT}"
}


# Setup the internal target environment
# Context: target
inplace_target_setup () {
    hostname=NONE
    fullname=NONE
    username=
    language=
    region=
    use_encryption=no
    while getopts ":L:H:N:U:R:E" OPT ; do
        case ${OPT} in
            E) use_encryption=yes ;;
            H) hostname="${OPTARG}" ;;
            N) fullname="${OPTARG}" ;;
            U) username="${OPTARG}" ;;
            R) region="${OPTARG}" ;;
            L) language="${OPTARG}" ;;
        esac
    done

    ${language:=en_US.UTF-8}
    ${region:=America/Los_Angeles}


    echo "${hostname}" > /etc/hostname
    echo 'KEYMAP=us' > /etc/vconsole.conf # TODO

    ln -sf /usr/share/zoneinfo/${region} /etc/localtime
    hwclock --systohc


    sed -i -E "s/[#]*(${language} .*)$/\1/"  /etc/locale.gen
    echo "LANG=${language}" > /etc/locale.conf
    locale-gen

    # This replaces "udev", "resume", and "encrypt" with systemd components
    HOOKS=(base systemd autodetect modconf kms keyboard sd-vconsole block sd-encrypt lvm2 filesystems btrfs fsck)
    FILES=()
    MODULES=(usbhid xhci_hcd vfat btrfs)
    BINARIES=(/usr/bin/btrfsck /usr/bin/btrfs)


    tpmdrv=$(get_tpm_module_driver)
    secureboot_setup_active
    has_sb=$?


    test -n "${tpmdrv}" -a 0 -eq ${has_sb} -a 'yes' = "${use_encryption}"
    actually_secure=$?

    if [[ "yes" = ${use_encryption} ]]; then


        if [[ 0 -eq ${actually_secure} ]] ; then
            MODULES+=(${tpmdrv})

            test -f /etc/luks.key && | while read deviceuuid; do
                systemd-cryptenroll /dev/disk/by-uuid/${deviceuuid} \
                    --wipe-slot=empty \
                    --tpm2-device=auto \
                    --tpm2-pcrs=1+2+3+4+7+15 \
                    --tpm2-with-pin=yes
            done < <(grep "/etc/luks.key" /etc/crypttab.initramfs | grep -oE 'UUID=[a-f0-9\-]+' | cut -d = -f 2)

            sed 's%/etc/luks.key%none\ttpm2-device=auto%g' /etc/crypttab.initramfs
            echo "root=/dev/system/root rootflags=subvol=@root" >> /etc/kernel/cmdline

            sbctl setup
            sbctl create-keys
            sbctl enroll-keys --microsoft



        else # when the system doesn't have TPM or doesn't support SecureBoot
            # this adds the keyfile to the initramfs.
            # this is insecure.
            FILES+=(/etc/luks.key)

        fi

    fi

    echo "rw quiet splash add_efi_memmap" >> /etc/kernel/cmdline

    echo "s%^((MODULES=)\(.*\))%\2\(${MODULES[@]}\)%" | sed -E -f - -i /etc/mkinitcpio.conf
    echo "s%^((HOOKS=)\(.*\))%\2\(${HOOKS[@]}\)%" | sed -E -f - -i /etc/mkinitcpio.conf
    echo "s%^((BINARIES=)\(.*\))%\2\(${BINARIES[@]}\)%" | sed -E -f - -i /etc/mkinitcpio.conf
    echo "s%^((FILES=)\(.*\))%\2\(${FILES[@]}\)%" | sed -E -f - -i /etc/mkinitcpio.conf

    echo "s%/efi/EFI%/boot/EFI%" | sed -E -f - -i /etc/mkinitcpio.d/*.preset
    echo "s%^#((default|fallback)_uki)%\1%" | sed -E -f - -i /etc/mkinitcpio.d/*.preset


    mkinitcpio -P
    test 0 -eq "${actually_secure}" && sbctl sign-all

    bootctl install
    sed -i -E 's%^#(timeout|console-mode)%\1%' /boot/loader/loader.conf

    sed -i -E "s@^[# ]+(%(wheel|sudo))@\1@" /etc/sudoers

    useradd --btrfs-subvolume-home -c "${fullname}" -U -G sudo,users -m ${username}
    passwd ${username}


    systemctl enable systemd-networkd
    systemctl enable systemd-resolved
    systemctl enable sshd
}


# Main setup flow
# Context: liveiso
do_setup () {

    volume_occupy="100%FREE"
    use_encryption=no
    crypt_passphrase=NONE
    passdown_args=()
    while getopts ":EK:H:N:U:P:" OPT ; do
        case ${OPT} in
            E) use_encryption=yes ;;
            K) echo "${OPTARG}" > /tmp/cryptkey ;
                crypt_passphrase="/tmp/cryptkey" ;;
            H|N|U|L|R) passdown_args+=("-${OPT} '${OPTARG}'") ;;
            P) volume_occupy="${OPTARG}" ;;
        esac
    done


    timedatectl  # refresh time

    BLOCKDEVICES=$(mktemp /tmp/devices.XXXXXX)
    find_target_disk > ${BLOCKDEVICES}

    # Sets up the partitions & filesystems, mounting at /mnt
    do_disk_setup ${BLOCKDEVICES} ${use_encryption} ${crypt_passphrase} ${volume_occupy}

    target_files /mnt
    do_package_setup /mnt ${use_encryption}

    # Switch to target setup mode
    cp -v ${0} /mnt/tmp/
    arch-chroot /mnt bash -x /tmp/archsetup.sh target "${passdown_args[@]}"
}

case ${1} in
    setup)  do_setup "${@[@]:1}";;
    target) inplace_target_setup "${@[@]:1}" ;;
esac
