# Handoff — Xiaomi Pad 6 (pipa) multiboot + AERA Recovery

Written 2026-10-11 for whoever picks this up next. Everything below was
verified on the actual hardware unless marked otherwise.

---

## 1. Current state

### DONE — EndeavourOS ARM on the tablet, dual-booting with LineageOS

The tablet boots a working Plasma desktop. Verified: rootfs grew into the full
128 GiB, Mu-Silicium UEFI → GRUB chain works, LineageOS still intact.

| Slot | Contents |
|---|---|
| `a` | Mu-Silicium UEFI → GRUB → EndeavourOS (kernel `7.1.7-pipa+`) |
| `b` | LineageOS (Android 16) — **untouched** |

Switch OS: `fastboot set_active a|b` then `fastboot reboot`.

**`userdata` is blank.** The repartition wiped it (user explicitly approved).
Slot `b` will not boot until **Format Data** is run in LineageOS recovery
(works without root). KernelSU modules lived in `/data/adb`, so root there
needs re-setting-up.

### IN PROGRESS — AERA Recovery for pipa

Device tree is **written and pushed but never compiled**:
`koobie777/device_xiaomi_pipa-AERA` branch `aera-16.0` (the default branch).

WSL2 was just set up to build it. See §4 for the exact next commands.

### DEFERRED — Windows on ARM (tri-boot)

User wants to revisit *after* AERA works. See §6 before spending effort — the
honest verdict is it is probably not worth it.

---

## 2. Hardware facts (read off the device, not copied from a guide)

- Codename `pipa`, model 23043RP34G, serial `5e0c1bf5`
- SM8250 (Snapdragon 870), platform name **`kona`**, Adreno 650
- **4096-byte logical sectors** on `/dev/block/sda` — never assume 512
- `/data` is **f2fs** under metadata encryption (dm-default-key)
- **Virtual A/B**: `ro.virtual_ab.enabled=true`, and `lpdump` shows *only* `_b`
  logical partitions. There is no `system_a`. That is what makes slot `a` free
  for a separate UEFI/Linux boot chain.
- Recovery-as-boot: there is **no** `recovery` partition

Partition layout after our changes:

| Partition | # | Size | Use |
|---|---|---|---|
| `rawdump` | 27 | 128 MiB | ESP for Linux (repurposed) |
| `cust` | 28 | 1024 MiB | `/boot` for Linux (repurposed) |
| `super` | 29 | 8.5 GiB | Android dynamic partitions (`_b` only) |
| `userdata` | 34 | 97.76 GiB | Android (**currently unformatted**) |
| `linux` | 35 | 128 GiB | EndeavourOS rootfs (**we created this**) |
| `boot_a`/`boot_b` | — | 192 MiB ea. | UEFI / Android kernel |

`cust` and `rawdump` were safe to repurpose: both unmounted, absent from every
fstab, `cust` held only a leftover Xiaomi ext4 volume. **Re-verify on any other
unit before trusting this.**

---

## 3. Gotchas — read these before touching anything

These each cost real debugging time. Do not rediscover them.

1. **`fastboot` cannot flash the ~11 GiB rootfs on Windows.** It dies with
   `libc++abi: ... std::bad_alloc` *before transferring anything*. `-S 256M`
   does **not** help. A 1 GiB file to the same partition works fine, so it is
   purely image size. Use `tools/split-sparse.py` in the endeavouros-pipa repo,
   which emits Android sparse files directly; flash the chunks in order.

2. **Upstream's `flash-multiboot.sh` erases `dtbo_ab` — that is BOTH slots.**
   On a dual-boot device this breaks Android. Use
   `tools/Flash-PipaMultiboot.ps1`, which erases only the Linux slot's `dtbo`.

3. **LineageOS recovery is useless for disk work.** adbd runs as `uid=2000`,
   `adb root` is refused ("production builds"), there is no `sgdisk`, and
   `/tmp`, `/dev`, `/sdcard`, `/cache`, `/mnt` all refuse writes. Do not plan
   around it.

4. **`/data` cannot be remounted read-only.** f2fs returns `EBUSY` while ~25
   processes hold it open, even after `stop`. Kill the holders and `umount`
   instead — which is better anyway, since the kernel can then re-read the
   partition table.

5. **A script that unmounts `/data` cannot live on `/data`.** Its own file
   vanishes mid-run. Copy it to `/dev` (tmpfs, root-writable) and run it there.
   The kill loop must also spare `adbd` and its shell, or the script dies
   before it can issue the reboot.

6. **Never pass inline shell snippets from PowerShell to another shell.**
   `$p`, `$(...)` and escaped quotes get eaten by PowerShell before `adb` or
   `wsl` ever sees them — and *single quotes do not reliably protect them
   either* through this tooling. Symptoms are silent: `for p in a b c` ran with
   `$p` empty and cheerfully reported every package missing. Always write a
   `.sh` file and invoke the file:
   - device: `adb push x.sh /data/local/tmp/ && adb shell "su -c 'sh /data/local/tmp/x.sh'"`
   - WSL: `wsl -d Ubuntu-24.04 -- bash /mnt/c/path/to/x.sh`

   A command line with no `$` and no nested quotes is safe inline; anything
   else goes in a file.

7. **AERA device trees use `AERA_*` names only.**
   `bootable/recovery/aera_config.mk` translates them to the backend's internal
   `TW_*`/`OF_*` flags. Setting the internal names directly bypasses that
   layer. Rule: every `TW_FOO`/`OF_FOO`/`TWRP_FOO` becomes `AERA_FOO`, with a
   few explicit renames (`AERA_COMPATIBILITY_MODE`,
   `AERA_INCLUDE_RECOVERY_INJECTION`, `AERA_SKIP_LEGACY_PATCH_PROCESS`,
   `AERA_NO_REFLASH_CURRENT_RECOVERY`, `AERA_INCLUDE_LOGCAT`). AOSP
   `BOARD_*`/`TARGET_*`/`PRODUCT_*` keep upstream names.

8. **`aera_<device>.mk` is NOT a product makefile.** It holds `AERA_*` config
   and is inherited from `device.mk`. The product makefile and lunch target
   stay `twrp_<device>`. The pre-existing `device_xiaomi_pipa-AERA` repo got
   this wrong (`PRODUCT_NAME := aera_pipa`), which is why we rebuilt from the
   TWRP tree instead.

9. **Do not re-add the ColorOS 17 property rewrite.** The TWRP pipa tree we
   derived from forces `ro.build.version.release=17` and security patches to
   `2026-09-01` for a ported Android 17 ROM. Keymaster stores
   `os_version`/`os_patchlevel` in the key blobs it creates, so a recovery
   claiming the wrong Android version is answered `KEY_REQUIRES_UPGRADE` and
   **cannot decrypt `/data`**. This tree targets Android 16. The
   `twrp.drm.direct_scanout=0` override *is* kept — real perf fix on this panel
   (~4 fps without it).

10. **The published EndeavourOS downloads expire.** Upstream ships images only
    as CircleCI *job artifacts* (30-day retention), which is why the XDA link
    is dead. Rebuild with the GitHub Actions workflow instead (§5).

11. **WSL**: `wsl --manage ... --move` fails with `ERROR_SHARING_VIOLATION`
    unless you `wsl --shutdown` first. And `autoMemoryReclaim`/`sparseVhd`
    belong under `[experimental]` in `.wslconfig`, not `[wsl2]`.

12. **Ubuntu 24.04 dropped `libncurses5`/`libtinfo5`**, which some AOSP host
    prebuilts still link against. `build-host/setup-build-env.sh` symlinks the
    `.6` SONAMEs to `.5`.

13. **`repo sync` of `aera-16.0` tries SSH and stalls.** The manifest points
    AERA-owned projects at `git@github.com:`, and `repo init -u https://...`
    only overrides the *manifest repo's* URL, not the per-project remotes
    inside it. The sync floods the terminal with
    `The authenticity of host 'github.com' can't be established` and dies with
    `RepoUnhandledExceptionError` around a third of the way through. No key is
    needed — the repos are public — so rewrite the URLs:

    ```bash
    git config --global --add url."https://github.com/".insteadOf "git@github.com:"
    git config --global --add url."https://github.com/".insteadOf "ssh://git@github.com/"
    ```

    **`--add` is mandatory.** Both rewrites write the same config key
    (`url.https://github.com/.insteadof`), so without it the second silently
    replaces the first and half the URLs stay broken. `build-host/fix-remotes.sh`
    does this and verifies three AERA repos resolve before you resync.
    `repo sync` is resumable, so just re-run it afterwards.

---

## 4. NEXT TASK — build AERA Recovery

Build env is Ubuntu 24.04 under WSL2, distro at `F:\wsl\Ubuntu-24.04`, user
`cj`, 28 cores, 25 GB RAM, 24 GB swap, ~955 GB free. `repo` is at `~/bin/repo`.

```bash
# in WSL: wsl -d Ubuntu-24.04
mkdir -p ~/android/AERA_16.0 && cd ~/android/AERA_16.0

repo init -u https://github.com/AERA-Recovery/android_manifest.git -b aera-16.0
repo sync -c --force-sync --no-clone-bundle --no-tags -j$(nproc)

git clone -b aera-16.0 \
    https://github.com/koobie777/device_xiaomi_pipa-AERA.git \
    device/xiaomi/pipa

source build/envsetup.sh
lunch twrp_pipa-bp2a-eng
mka adbd recoveryimage
```

Output: `out/target/product/pipa/recovery.img` (or `boot.img`, since this tree
is `BOARD_USES_RECOVERY_AS_BOOT`).

**The manifest README claims AERA's repos are in a private org needing an SSH
key. That is stale** — they are public and the HTTPS clone above works
anonymously (verified with `git ls-remote`).

**Expect build failures.** This tree has never been compiled. Likely areas:
- the disabled repack/resetprop tools (Magisk prebuilt's legacy `Android.mk` is
  rejected by the A16 Soong scanner) — already commented out, keep them off
- `BUILD_BROKEN_PLUGIN_VALIDATION` plugin names may differ under AERA
- dodge's tree has `audio/`, `gpu/`, `security/` dirs we deliberately omitted;
  if the AERA build *requires* them, add minimal stubs rather than copying
  dodge's OnePlus-specific binaries

### Testing the result — IMPORTANT

```bash
fastboot boot recovery.img      # RAM-only, non-destructive. ALWAYS do this first.
```

**Never flash an untested recovery.** This tree is recovery-as-boot, so a bad
flash to `boot_b` would break Android's boot path. Also note the tablet
currently has **slot `a` = EndeavourOS**; flashing recovery to `boot_a` would
destroy the Linux install. Target `boot_b` only, and only after `fastboot boot`
proves it works.

Values flagged as needing on-device tuning (see the tree's README):
- `AERA_STATUS_H := 145` — scaled from the reference tree, not measured
- `AERA_ENABLE_WLAN := 0` — needs `AERA_LOAD_VENDOR_MODULES` populated
- `AERA_FRAMERATE := 120` — panel is actually 144 Hz

---

## 5. Rebuilding the EndeavourOS image

```bash
gh workflow run build-image.yml --repo koobie777/endeavouros-pipa -f desktop=plasma
```

~11 minutes on free `ubuntu-24.04-arm` runners, 90-day artifact retention. No
kernel compile — `linux-pipa` comes prebuilt from the `pipa-pkgs` pacman repo.
The workflow relocates Docker's data-root because the build holds the rootfs
tree, the raw images *and* the zip at once (~25 GB).

Then: `gh run download <id> --repo koobie777/endeavouros-pipa`, extract, and

```powershell
.\tools\Flash-PipaMultiboot.ps1 -ImageDir .\endeavouros-pipa-plasma-YYYYMMDD -WhatIf
```

It auto-splits images over 4 GiB (gotcha #1), verifies `SHA256SUMS`, checks
partition sizes, and leaves the Android slot alone.

---

## 6. Windows on ARM — read before investing

Mu-Silicium (already on `boot_a`) is literally the WOA UEFI firmware, so the
hard part is done. **The blocker is drivers, and it is structural:**

- There has **never** been a retail Windows device on SM8250, so no Qualcomm
  signed Windows driver set exists for 865/870.
- Nobody writes an Adreno driver from scratch. For Adreno 650 on Windows the
  binary does not exist. Hard ceiling.
- Renegade Project's `WOA-Drivers` was last updated **Feb 2023**; their
  `edk2-msm` is self-described as *"Broken"*.
- XDA's pipa Windows guide says the **touchscreen is not supported** (bring a
  USB keyboard/mouse). The main pipa WOA repo says *"no drivers yet"*,
  *"VERY UNSTABLE"*.
- There is an open Mu-Silicium issue: self-built pipa UEFI fails in DXE with
  OOM / `INACCESSIBLE_BOOT_DEVICE`.

**The one cheap question worth answering first:** does pipa's touch controller
speak **HID-over-I²C**? If so, Windows' *inbox* `HIDI2C` driver can drive it
with correct ACPI alone — no driver authoring. Mainline Linux has pipa's
touchscreen working, and there is a 623-line upstream `sm8250-xiaomi-pipa.dts`
(plus `prebuilt/dtb` in our tree) to read the controller and its wiring from.
That answer decides whether tri-boot is an afternoon of ACPI work or a dead
end. Do that lookup before anything else.

Realistic best case even if it all works: UEFI-framebuffer display with no GPU
acceleration — a software-rendered Windows. A flex, not an OS.

---

## 7. Repos and local paths

Forks on `koobie777` (all forked so upstream cannot disappear):

| Repo | Why |
|---|---|
| `endeavouros-pipa` | image builder + our tooling, **has the CI workflow** |
| `device_xiaomi_pipa-AERA` | **our AERA tree**, branch `aera-16.0` |
| `twrp_device_xiaomi_pipa` | the TWRP 16.0 base we derived from |
| `android_manifest` | AERA manifest |
| `android_bootable_recovery` | AERA core (has `aera_config.mk`) |
| `android_vendor_recovery` | AERA vendor build system |
| `android_device_oneplus_dodge-AERA` | reference AERA tree to crib from |
| `pipa-pkgs` | pipa pacman packages (incl. `linux-pipa`) |
| `Mu-Silicium` | the UEFI firmware |
| `linux` | pipa kernel source |

Local, on the Windows host:

```
C:\Users\CJ\pipa-eos\
  endeavouros-pipa\              fork + tools\ (flasher, repartition, splitter)
  images\                        built image zip + extracted
  backups\pipa-gpt-backup.bin    pre-repartition GPT (sha256 c0ed51f8...)
  aera\
    device_xiaomi_pipa-AERA\     our AERA tree
    ref\                         twrp-pipa, dodge-aera, aera-vendor, etc.
    setup-build-env.sh           WSL build-env bootstrap
  HANDOFF.md                     this file
```

`adb`/`fastboot`: `C:\AdbTool\platform-tools`. Host has **no Docker**; UAC is
off and sessions run as admin, so there is no elevation prompt as a safety net
— be deliberate with system changes.

---

## 8. User context

- GitHub `koobie777`, email `cdrennon@gmail.com`
- Comfortable with fastboot/adb, rooted devices, offered to boot fastbootd
  unprompted. Does not need hand-holding on Android internals.
- Explicitly approved the userdata wipe. Wants AERA working, then Windows
  revisited. Asked for everything cloned to their GitHub "in case we need it".
- Prefers being told plainly when something will not work over optimistic
  hedging.
