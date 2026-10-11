#!/system/bin/sh
#
# Shrink userdata and carve out a dedicated `linux` partition on the Xiaomi
# Pad 6 (pipa), running from a ROOTED, BOOTED Android.
#
# Why not recovery: LineageOS recovery runs adbd as uid 2000, refuses
# `adb root` on production builds, ships no sgdisk, and has nothing writable.
#
# The hazard of rewriting a GPT from a running system is that the kernel keeps
# using the OLD table (BLKRRPART returns EBUSY while userdata is mounted), so
# Android could write past the new boundary. MODE=apply closes that window by
# stopping the framework, killing everything holding /data, and UNMOUNTING it
# before touching the table, then rebooting straight to the bootloader.
#
# Remounting /data read-only does not work on this device: f2fs returns EBUSY
# while writers are attached, so we unmount instead.
#
# Run this from a tmpfs path (e.g. /dev), NOT from /data -- the script's own
# file would vanish mid-run when /data is unmounted.
#
# THIS DESTROYS ALL ANDROID USER DATA.
#
# Usage:
#   MODE=plan  LINUX_GIB=128 sh /dev/repart.sh    # writes nothing
#   MODE=apply LINUX_GIB=128 sh /dev/repart.sh    # destructive

set -u

DISK=/dev/block/sda
UD_NUM=34                 # userdata's GPT partition number
NEW_NUM=35                # the linux partition we add
UD_TYPE=A03A              # sgdisk shorthand: Android user data
LINUX_TYPE=8300           # sgdisk shorthand: Linux filesystem
LINUX_GIB="${LINUX_GIB:-128}"
MODE="${MODE:-plan}"
BACKUP=/data/local/tmp/pipa-gpt-backup.bin
# Last-resort escape hatch: proceed even if /data refuses to unmount.
ALLOW_MOUNTED="${ALLOW_MOUNTED:-0}"

cd /

die() { echo "FATAL: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
command -v sgdisk >/dev/null 2>&1 || die "sgdisk not found"
[ -b "$DISK" ] || die "$DISK is not a block device"

case "$LINUX_GIB" in
    ''|*[!0-9]*) die "LINUX_GIB must be a whole number of GiB, got '$LINUX_GIB'" ;;
esac
# The rootfs image is ~11.2 GiB and auto-grows to fill the partition.
[ "$LINUX_GIB" -ge 12 ] || die "LINUX_GIB=$LINUX_GIB is smaller than the rootfs image"
[ "$LINUX_GIB" -le 200 ] || die "LINUX_GIB=$LINUX_GIB would leave Android nothing"

echo "### Sanity checks"

dev=$(getprop ro.product.device)
[ "$dev" = "pipa" ] || die "device reports '$dev', expected 'pipa'"
echo "  device is pipa                     OK"

ud_name=$(sgdisk --info="$UD_NUM" "$DISK" 2>/dev/null \
    | sed -n "s/^Partition name: '\(.*\)'$/\1/p")
[ "$ud_name" = "userdata" ] \
    || die "partition $UD_NUM is named '$ud_name', expected 'userdata'"
echo "  partition $UD_NUM is 'userdata'       OK"

if sgdisk --print "$DISK" | grep -qw linux; then
    die "a partition named 'linux' already exists -- nothing to do"
fi
echo "  no existing 'linux' partition      OK"

case "$0" in
    /data/*) die "run this from a tmpfs path such as /dev, not from /data" ;;
esac
echo "  script is not on /data             OK"

ud_info=$(sgdisk --info="$UD_NUM" "$DISK")
ud_first=$(printf '%s\n' "$ud_info" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
ud_last=$(printf '%s\n' "$ud_info" | sed -n 's/^Last sector: \([0-9]*\).*/\1/p')
[ -n "$ud_first" ] && [ -n "$ud_last" ] || die "could not read userdata geometry"

# pipa's UFS reports 4096-byte logical sectors; never assume 512.
sector_bytes=$(cat /sys/block/sda/queue/logical_block_size 2>/dev/null || echo 4096)
sectors_per_gib=$((1024 * 1024 * 1024 / sector_bytes))
cur_gib=$(((ud_last - ud_first + 1) / sectors_per_gib))
echo "  logical sector size ${sector_bytes}B        OK"

echo
echo "### Plan"
echo "  disk                 $DISK"
echo "  userdata now         sectors $ud_first..$ud_last (${cur_gib} GiB)"
echo "  new linux partition  ${LINUX_GIB} GiB at the end of the disk"
echo "  userdata after       ~$((cur_gib - LINUX_GIB)) GiB"
echo "  mode                 $MODE"

SGDISK_OPS="--delete=$UD_NUM
--new=$UD_NUM:$ud_first:-${LINUX_GIB}G
--typecode=$UD_NUM:$UD_TYPE
--change-name=$UD_NUM:userdata
--new=$NEW_NUM:0:0
--typecode=$NEW_NUM:$LINUX_TYPE
--change-name=$NEW_NUM:linux"

if [ "$MODE" != "apply" ]; then
    echo
    echo "### Writing a partition-table backup (safe, no layout change)"
    rm -f "$BACKUP"
    sgdisk --backup="$BACKUP" "$DISK" || die "could not write the GPT backup"
    echo "  backup written to $BACKUP"
    echo "  PULL IT TO YOUR PC NOW:  adb pull $BACKUP"

    echo
    echo "### Dry run (sgdisk --pretend; nothing is written)"
    # shellcheck disable=SC2086
    sgdisk --pretend $SGDISK_OPS --print "$DISK" | tail -6

    echo
    echo "Nothing was changed. To apply:"
    echo "  MODE=apply LINUX_GIB=$LINUX_GIB sh $0"
    exit 0
fi

# ---------------------------------------------------------------- destructive
echo
echo "### APPLYING -- this erases all Android user data"

[ -f "$BACKUP" ] || echo "  WARNING: no GPT backup at $BACKUP (hope you pulled it)"

echo
echo "### Quiescing Android"
# Stop the framework. We are rebooting to the bootloader straight after, so
# leaving Android in a wrecked state is fine and lets us be aggressive.
stop 2>/dev/null || true
setprop ctl.stop zygote 2>/dev/null || true
setprop ctl.stop zygote_secondary 2>/dev/null || true
setprop ctl.stop update_engine 2>/dev/null || true
sleep 3
sync
echo "  framework stopped, writes synced"

# Never kill ourselves, our parent chain, init, or adbd (killing adbd would
# drop the shell this script is running in, before it can reboot the device).
self=$$
keep="1 $self ${PPID:-0}"
for p in /proc/[0-9]*; do
    pid=${p##*/}
    comm=$(cat "$p/comm" 2>/dev/null) || continue
    case "$comm" in adbd|su|sh|init) keep="$keep $pid" ;; esac
done

echo "  killing processes holding /data open"
killed=0
for p in /proc/[0-9]*; do
    pid=${p##*/}
    skip=0
    for k in $keep; do [ "$pid" = "$k" ] && skip=1 && break; done
    [ "$skip" -eq 1 ] && continue

    hit=0
    for fd in "$p"/fd/*; do
        t=$(readlink "$fd" 2>/dev/null) || continue
        case "$t" in /data/*) hit=1; break ;; esac
    done
    if [ "$hit" -eq 0 ] && grep -qm1 ' /data/' "$p/maps" 2>/dev/null; then hit=1; fi
    if [ "$hit" -eq 1 ]; then
        kill -9 "$pid" 2>/dev/null && killed=$((killed + 1))
    fi
done
echo "  killed $killed process(es)"
sleep 2
sync

echo
echo "### Unmounting /data"
# Unmount every bind/sub mount under /data first, deepest path first, or the
# main unmount stays busy.
for m in $(mount | awk '{print $3}' | grep '^/data' | sort -r); do
    umount "$m" 2>/dev/null && echo "  unmounted $m"
done
umount /data 2>/dev/null || umount -l /data 2>/dev/null || true
sleep 1

if mount | grep -q ' /data '; then
    if [ "$ALLOW_MOUNTED" = "1" ]; then
        echo "  WARNING: /data still mounted, continuing because ALLOW_MOUNTED=1" >&2
    else
        echo "FATAL: /data is still mounted; refusing to rewrite the table." >&2
        echo "       Re-run with ALLOW_MOUNTED=1 to override, or reboot and retry." >&2
        exit 1
    fi
else
    echo "  /data is unmounted                 OK"
fi

echo
echo "### Rewriting the partition table"
# shellcheck disable=SC2086
sgdisk $SGDISK_OPS "$DISK"
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "  sgdisk exit code $rc (non-fatal if it only failed to re-read the table)"
fi

echo
echo "### Verifying the new table on disk"
sgdisk --print "$DISK" | tail -4
new_name=$(sgdisk --info="$NEW_NUM" "$DISK" 2>/dev/null \
    | sed -n "s/^Partition name: '\(.*\)'$/\1/p")
echo
if [ "$new_name" = "linux" ]; then
    echo "  partition $NEW_NUM is now 'linux'     OK"
else
    echo "  WARNING: partition $NEW_NUM reads as '$new_name'" >&2
fi

echo
echo "### Rebooting to the bootloader"
sync
reboot bootloader
