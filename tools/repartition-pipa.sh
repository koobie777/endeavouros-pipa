#!/sbin/sh
#
# Shrink userdata and carve out a dedicated `linux` partition on the Xiaomi
# Pad 6 (pipa), for the multiboot install mode.
#
# RUN THIS FROM RECOVERY (TWRP / OrangeFox) WITH /data UNMOUNTED.
# Running it under a booted Android cannot work: the kernel will not re-read
# the partition table while userdata is mounted and in use.
#
# This DESTROYS everything in userdata. Android must be re-set-up afterwards.
#
# Usage:
#   LINUX_GIB=64 CONFIRM=YES sh repartition-pipa.sh
#
# Dry run (prints the plan, writes nothing):
#   LINUX_GIB=64 sh repartition-pipa.sh

set -eu

DISK=/dev/block/sda
UD_NUM=34                 # userdata's GPT partition number
NEW_NUM=35                # the linux partition we add
UD_TYPE=A03A              # sgdisk shorthand: Android user data
LINUX_TYPE=8300           # sgdisk shorthand: Linux filesystem
LINUX_GIB="${LINUX_GIB:-64}"
CONFIRM="${CONFIRM:-no}"
BACKUP=/tmp/pipa-gpt-backup.bin

die() { echo "FATAL: $*" >&2; exit 1; }

command -v sgdisk >/dev/null 2>&1 || die "sgdisk not found; boot TWRP/OrangeFox, not stock recovery"
[ -b "$DISK" ] || die "$DISK is not a block device"

case "$LINUX_GIB" in
    ''|*[!0-9]*) die "LINUX_GIB must be a whole number of GiB, got '$LINUX_GIB'" ;;
esac
[ "$LINUX_GIB" -ge 12 ] || die "LINUX_GIB=$LINUX_GIB is too small; the rootfs image alone is ~10 GiB"
[ "$LINUX_GIB" -le 200 ] || die "LINUX_GIB=$LINUX_GIB would leave Android almost nothing"

echo "### Sanity checks"

# Refuse to touch a disk whose layout is not the one this script was written
# against. Partition 34 must still be userdata.
ud_name=$(sgdisk --info="$UD_NUM" "$DISK" 2>/dev/null \
    | sed -n "s/^Partition name: '\(.*\)'$/\1/p")
[ "$ud_name" = "userdata" ] \
    || die "partition $UD_NUM is named '$ud_name', expected 'userdata' -- aborting"
echo "  partition $UD_NUM is 'userdata'  OK"

# A `linux` partition must not already exist, or we would create a duplicate.
if sgdisk --print "$DISK" | grep -qw linux; then
    die "a partition named 'linux' already exists -- nothing to do"
fi
echo "  no existing 'linux' partition      OK"

# /data mounted means we are not in recovery, or recovery auto-mounted it.
if mount | grep -q ' /data '; then
    echo "  /data is MOUNTED -- attempting to unmount"
    umount /data || die "could not unmount /data; unmount it in recovery first"
fi
mount | grep -q ' /data ' && die "/data still mounted"
echo "  /data not mounted                  OK"

ud_first=$(sgdisk --info="$UD_NUM" "$DISK" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
ud_last=$(sgdisk --info="$UD_NUM" "$DISK" | sed -n 's/^Last sector: \([0-9]*\).*/\1/p')
[ -n "$ud_first" ] && [ -n "$ud_last" ] || die "could not read userdata geometry"

# pipa's UFS reports 4096-byte logical sectors; confirm before doing GiB math.
sector_bytes=$(cat /sys/block/sda/queue/logical_block_size 2>/dev/null || echo 4096)
sectors_per_gib=$((1024 * 1024 * 1024 / sector_bytes))
total_sectors=$((ud_last - ud_first + 1))

echo
echo "### Plan"
echo "  disk                 $DISK"
echo "  logical sector size  ${sector_bytes} bytes"
echo "  userdata now         sectors $ud_first..$ud_last ($((total_sectors / sectors_per_gib)) GiB)"
echo "  new linux partition  ${LINUX_GIB} GiB at the end of the disk"
echo "  userdata after       ~$(( (total_sectors / sectors_per_gib) - LINUX_GIB )) GiB"
echo
echo "  GPT backup           $BACKUP"
echo
echo "  THIS ERASES ALL ANDROID USER DATA."

if [ "$CONFIRM" != "YES" ]; then
    echo
    echo "Dry run only. Re-run with CONFIRM=YES to apply:"
    echo "  LINUX_GIB=$LINUX_GIB CONFIRM=YES sh \$0"
    echo
    echo "### --pretend output from sgdisk"
    sgdisk --pretend \
        --delete="$UD_NUM" \
        --new="$UD_NUM:$ud_first:-${LINUX_GIB}G" \
        --typecode="$UD_NUM:$UD_TYPE" \
        --change-name="$UD_NUM:userdata" \
        --new="$NEW_NUM:0:0" \
        --typecode="$NEW_NUM:$LINUX_TYPE" \
        --change-name="$NEW_NUM:linux" \
        "$DISK"
    exit 0
fi

echo
echo "### Backing up the partition table to $BACKUP"
sgdisk --backup="$BACKUP" "$DISK"
echo "  pull it to your PC before rebooting:"
echo "    adb pull $BACKUP"

echo
echo "### Repartitioning"
# One sgdisk invocation so the table is rewritten once, not three times.
sgdisk \
    --delete="$UD_NUM" \
    --new="$UD_NUM:$ud_first:-${LINUX_GIB}G" \
    --typecode="$UD_NUM:$UD_TYPE" \
    --change-name="$UD_NUM:userdata" \
    --new="$NEW_NUM:0:0" \
    --typecode="$NEW_NUM:$LINUX_TYPE" \
    --change-name="$NEW_NUM:linux" \
    "$DISK"

echo
echo "### Result"
sgdisk --print "$DISK" | tail -5
echo
sgdisk --verify "$DISK" || true

echo
echo "### Done."
echo "Next steps:"
echo "  1. Reboot back into recovery so the new table is re-read."
echo "  2. Format Data (userdata is now an unformatted, smaller partition)."
echo "  3. Reboot to fastboot and run the flasher for the Linux side."
