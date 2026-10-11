# Multiboot tooling for Xiaomi Pad 6 (pipa)

Helpers for installing EndeavourOS ARM alongside Android on a pipa, and for
rebuilding the image when the upstream download expires.

## Why these exist

**The published download links die.** Upstream ships images as CircleCI *job
artifacts*, which expire after 30 days. The links in the XDA thread point at
job #64 (3 Sep 2026) and are long gone, with no GitHub release as a fallback.
`.github/workflows/build-image.yml` rebuilds the same images on GitHub's free
native-aarch64 runners with up to 90-day retention.

**Upstream's multiboot flasher is not slot-safe.** `flash-multiboot.sh` offers
to erase `dtbo_ab`, and the `_ab` suffix means *both* slots. On a device whose
Android lives on one slot, that erases Android's `dtbo` too.
`Flash-PipaMultiboot.ps1` touches only the slot Linux is being installed to.

## How the dual boot works

pipa is a **Virtual A/B** device (`ro.virtual_ab.enabled=true`). `lpdump` shows
logical partitions for one slot only — there is no `system_a` — so the unused
slot is free for a completely separate boot chain:

| | Android slot | Linux slot |
|---|---|---|
| `boot_<slot>` | Android kernel | Mu-Silicium UEFI → GRUB |
| system | `super` logical partitions | — |
| rootfs | `userdata` | dedicated `linux` partition |
| `/boot` | — | `cust` (repurposed) |
| ESP | — | `rawdump` (repurposed) |

Pick the OS by setting the active slot:

```bash
fastboot set_active a    # or b
fastboot reboot
```

`cust` and `rawdump` are safe to repurpose on this device: both are unmounted,
absent from every fstab, and `cust` holds only a leftover Xiaomi ext4 volume.
Verify on your own unit before trusting that.

There is no MultiROM-style boot picker — GRUB appears only once UEFI is up.
LineageOS does not ship `/system/bin/bootctl`, so switching slots from inside
Android needs a module or a direct write to the bootloader control block;
from the bootloader it is the one command above.

## Partition sizes must match exactly

The builder writes fixed-size images (`ESP_SIZE_MB=128`, `BOOT_SIZE_MB=1024`
in `build-image.sh`). On pipa these match the stock partitions exactly:

| Image | Size | Target | Stock size |
|---|---|---|---|
| `endeavouros_esp.raw` | 128 MiB | `rawdump` | 128 MiB |
| `endeavouros_boot.raw` | 1024 MiB | `cust` | 1024 MiB |
| `silicium.img` | ~2.3 MiB | `boot_<slot>` | 192 MiB |
| `endeavouros_rootfs.raw` | ~11.2 GiB | `linux` | you create it |

Check yours before flashing, and shrink the builder's variables if they differ:

```bash
fastboot getvar partition-size:cust
fastboot getvar partition-size:rawdump
```

## fastboot cannot sparse the rootfs itself

On Windows, host-side fastboot dies with
`libc++abi: terminating due to uncaught exception of type std::bad_alloc`
before transferring anything when asked to flash the ~11 GiB rootfs, and
`-S 256M` does not help — it fails instantly, not partway. The same fastboot
(37.0.1) flashes a 1 GiB file to the same partition fine, so it is the image
size, not the device or the partition.

`split-sparse.py` works around it by generating the Android sparse files
directly. Each output file declares the full partition size and marks
everything outside its own slice `DONT_CARE`, so flashing them in order writes
the image piece by piece; all-zero slices become `FILL` chunks and transfer no
data at all.

```bash
python -I tools/split-sparse.py endeavouros_rootfs.raw ./sparse --slice-mib 256
for f in ./sparse/chunk.*.simg; do fastboot flash linux "$f" || break; done
```

`Flash-PipaMultiboot.ps1` does this automatically for images over
`-SplitAboveGiB` (default 4).

## Usage

### 1. Build an image

Run the **Build EndeavourOS pipa image** workflow (Actions tab, or
`gh workflow run build-image.yml -f desktop=plasma`), then download the
artifact. Takes about 11 minutes on `ubuntu-24.04-arm`.

### 2. Create the `linux` partition

`repartition-pipa.sh` runs from TWRP/OrangeFox.
`repartition-pipa-android.sh` runs from a **rooted, booted Android** — use this
if your recovery is LineageOS's, which runs adbd as uid 2000, refuses
`adb root` on production builds and ships no `sgdisk`.

Both **destroy all Android user data.** Plan first; it writes a GPT backup and
shows the exact resulting table without changing anything:

```bash
adb push tools/repartition-pipa-android.sh /data/local/tmp/repart.sh
adb shell "su -c 'cp /data/local/tmp/repart.sh /dev/repart.sh'"
adb shell "su -c 'MODE=plan LINUX_GIB=128 sh /dev/repart.sh'"
adb pull /data/local/tmp/pipa-gpt-backup.bin        # keep this
```

Then apply. It stops the framework, kills everything holding the data volume,
unmounts it, rewrites the table and reboots to the bootloader:

```bash
adb shell "su -c 'MODE=apply LINUX_GIB=128 sh /dev/repart.sh'"
```

It must be run from a tmpfs path such as `/dev` — a copy living on `/data`
would vanish mid-run when that volume is unmounted.

To undo the table change (this does **not** bring the data back):

```bash
sgdisk --load-backup=pipa-gpt-backup.bin /dev/block/sda
```

### 3. Flash

```powershell
# dry run: prints the plan, verifies checksums and partition sizes
.\tools\Flash-PipaMultiboot.ps1 -ImageDir .\endeavouros-pipa-plasma-YYYYMMDD -WhatIf

# for real
.\tools\Flash-PipaMultiboot.ps1 -ImageDir .\endeavouros-pipa-plasma-YYYYMMDD
```

It detects which slot Android is on, installs the UEFI chain on the other one,
verifies `SHA256SUMS`, refuses to start if the `linux` partition is missing or
too small, and leaves the Android slot's `dtbo`/`vbmeta` untouched.

Switch back and forth afterwards:

```powershell
.\tools\Flash-PipaMultiboot.ps1 -SwitchTo android
```

### 4. Restore Android

After repartitioning, `userdata` is unformatted and Android will not boot.
Use **Format Data** in LineageOS recovery, which works without root.

## Notes

- First Linux boot resizes the rootfs and runs setup; allow a few minutes.
- `hexagonrpcd-adsp-rootpd.service` is deliberately masked upstream, because
  enabling it breaks audio.
- Device fixes ship as packages, so `sudo pacman -Syu` picks them up without a
  reimage.
