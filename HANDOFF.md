# Handoff — Xiaomi Pad 6 (pipa) multiboot + AERA Recovery

Written 2026-10-11 for whoever picks this up next. Everything below was
verified on the actual hardware unless marked otherwise.

## Codex continuation — 2026-10-11

EndeavourOS still boots successfully (user reconfirmed after the AERA test).
**Slot B contains InfinityX, not LineageOS.** Its installed recovery identifies
as `infinity_pipa` and uses the Lineage recovery UI. The user confirmed Android
had not booted since the Linux setup, before today's RAM test; it currently
stalls on a logo/black screen. Earlier notes say repartitioning wiped userdata.
Verify the current data state before proposing a format; do not assume a new
format is authorized. No partition has been flashed or erased in this session.

Both builds succeeded: baseline at 19:17 EDT (18:04), dark/orange rebuild at
19:26 EDT (05:31). The ccache fix keeps all cache/temp directories under `out/`.
Use **`bootimage`**: with recovery-as-boot, `recoveryimage` produces no boot.img.
The WSL move from F: SATA HDD completed successfully; its VHD now resides at
`C:\wsl\Ubuntu-24.04` on Samsung NVMe, and swap is on C: too. Rebuild with:

```powershell
wsl -d Ubuntu-24.04 -- bash /home/cj/android/AERA_16.0/device/xiaomi/pipa/build-host/build-aera.sh
```

Multiboot fixes: `cust` is omitted from recovery fstab/flags because it contains
Linux `/boot`; automatic recovery reflashing is disabled. **The backend's
Install Recovery Ramdisk/repacker still writes both boot slots. Do not use
that action or a recovery installer ZIP on this tablet.** Select Android slot
B before recovery partition operations.

Generate `boot-fbboot.img` using `tools/make_fbboot_image.py`, then test it with
`fastboot boot`. The temporary flag forces recovery even when the bootloader
requests a normal boot. Never flash this variant. Its v3/v4 command-line size
and payload validation were corrected; all 12 synthetic image tests pass.

The first hardware RAM test was explicitly on slot B: `set_active b`, then
`fastboot boot boot-fbboot.img` succeeded at the bootloader, but the screen
stayed completely black and no USB device appeared. User manually rebooted
into installed recovery, then bootloader. We subsequently requested
`fastboot reboot recovery` for logs; after Advanced > Enable ADB, installed
recovery connected. `adb root` is denied (production build), and shell UID
2000 cannot read `/sys/fs/pstore`. No format, mount, installer, or flash ran.
No further AERA boot tests until the Android state is understood.

Installed recovery kernel: `4.19.325-cip131-st15-perf-g647558de9e61` (Aug 18).
Our prebuilt kernel: `4.19.325-cip135-st19-perf+` (Oct 5). Stock cmdline supplies
`androidboot.usbcontroller=a600000.dwc3`; `/proc/bootconfig` is absent. Our v3
image contains no DTB and uses the installed vendor_boot/DTBO on the active
slot. Compatibility is a candidate, not a proven failure cause.

Image audits confirm native UI executable/marker/font/dependencies, LZ4 kernel
support, and exclusion of protected Linux partitions from fstab/flags. Actual
init disassembly confirms the `twrpfastboot=1` forcing logic; the dynamic init
symlink and linker layout are intentional. The baseline unsigned AVB footer
verifies, but the header-only RAM helper invalidates its hash descriptor.
Keep that RAM variant separate and never flash it.

The user chose dark backgrounds with orange accents. `AERA_DEFAULT_ACCENT :=
ff6900` is compiled into both native UI and backend; saved colors take
precedence. Boot/fastboot/About branding uses the live accent. Sources are
pinned in `build-host/pipa-theme.xml`: core `f899c2b6406734838163f4cddd1d27cfeb32c9dc`
and vendor bridge `4034f96ac83ee734f776706145f126c1cf17bddd` on the maintainer's
`pipa-xiaomi-theme` branches. Go/C++ validation and the full orange build pass.

Windows artifacts:
- `aera/builds/2026-10-11-baseline/boot-fbboot.img` (tested; black screen)
- `aera/builds/2026-10-11-xiaomi-orange/boot.img` and `boot-fbboot.img` (not boot-tested)
- `aera/verification/` and baseline folder contain image/startup audit reports.

Next: retrieve EOS `/sys/fs/pstore` or `/var/lib/systemd/pstore` without clearing
them; inspect Android data/metadata without writes. User is considering running
Codex directly in EOS. Keep builds on the Windows NVMe host. CJ prefers visible
live output and concise regular progress updates.

## Claude continuation — 2026-10-11 (SSH access to the tablet)

**Android is not bootable right now, so SSH into EOS is the only way onto this
device.** It is also better than fastboot for diagnosis: with root you can read
the raw boot partitions, which makes testing hypotheses evidence-based and
makes flashing reversible.

### How to connect

The tablet runs sshd. Key is on the Windows host at
`C:\Users\CJ\pipa-eos\ssh\pipa_ed25519`, and the public half is committed at
`endeavouros-pipa:tools/claude-session.pub` (already in the tablet's
`authorized_keys`, listed twice — harmless).

```bash
# from WSL (the Windows OpenSSH client works too)
cp /mnt/c/Users/CJ/pipa-eos/ssh/pipa_ed25519 ~/.ssh/ && chmod 600 ~/.ssh/pipa_ed25519
ssh -i ~/.ssh/pipa_ed25519 koobie777@192.168.40.86
```

`192.168.40.86`, user `koobie777`, passwordless sudo is configured. Revoke
access with `sudo rm /etc/sudoers.d/zz-nopasswd` and by deleting the
`claude-session-pipa` lines from `~/.ssh/authorized_keys`.

### Three traps when driving it remotely

1. **The login shell is fish.** `ssh host "bash -lc \"...\""` does NOT work:
   fish parses the line first and mangles `$?`, `$(...)` and quoting before
   bash ever sees it. **Pipe a script in instead** — this is the only reliable
   shape:
   ```bash
   ssh ... "bash -s" < script.sh
   ```
   fish also has no `hostname` builtin; use `uname -n` or `/etc/hostname`.

2. **sudoers.d is read in lexical order and the last match wins.** This image
   ships `/etc/sudoers.d/wheel` (`%wheel ALL=(ALL:ALL) ALL`, password
   required). A drop-in named `99-nopasswd` sorts *before* `wheel`, so wheel
   overrode it and `sudo -n` kept failing while interactive sudo appeared to
   work (cached timestamp). The file must sort **after** `wheel` — hence
   `zz-nopasswd`. Verify with `sudo -k && sudo -n true`.

3. **Do not generate ssh keys from PowerShell.** `ssh-keygen -N '""'` passes a
   *literal two-quote passphrase*, so the key is encrypted and `BatchMode`
   silently fails to sign:
   ```
   debug1: Server accepts key: ... ED25519 ...
   debug2: we did not send a packet, disable method
   ```
   "Server accepts key" means the server already authorized it — a failure
   after that line is **client-side**, not a server or authorized_keys problem.
   Fix without regenerating: `ssh-keygen -p -f key -P '""' -N ''`.

### Findings from the EOS side

- **EOS is completely healthy.** `/` is `sda35` (`linux` partlabel, label
  `eos-pipa`, 128G, the resize held), `/boot` is `sda28` (`cust`), ESP is
  `sda27` (`rawdump`, label `EOSPIPAESP`). Booted via UEFI
  (`/sys/firmware/efi` present); GRUB loaded `(hd5,gpt28)/Image.gz`.
  `userdata` (`sda34`, 97.8G) has **no filesystem** — still unformatted.
- **`qbootctl` is installed** (needs root). So slots can be switched from EOS
  without a PC — but note that if you switch to a non-booting slot you need
  physical volume-key access to get back to fastboot.
- **pstore cannot capture anything new.** `/sys/fs/pstore/console-ramoops-0`
  is dated **Sep 24** and `systemd-pstore` is **disabled/inactive**, so the
  single slot stays permanently occupied and today's failed AERA boot was never
  recorded. Saved to `aera/logs/console-ramoops-0-sep24.txt` (893 KB; it is a
  wrapped buffer with no boot header, only a shutdown tail). **To capture a
  future failed boot, the slot has to be freed first** — removing the file in
  `/sys/fs/pstore` is what frees the backend entry, so copy it off before
  deleting.
- **The touchscreen is `NVT-ts-spi` — Novatek on SPI.** This settles the
  Windows-on-ARM question: the cheap hope was HID-over-I²C, which Windows can
  drive with its inbox `HIDI2C` driver and correct ACPI alone. SPI-attached
  Novatek has no inbox path, so touch would need a driver written from
  scratch. **Tri-boot is a dead end — treat it as closed, not deferred.**

### CRITICAL: the earlier "no boot" results were invalid tests

**Slot b's retry counter was already exhausted before any AERA test ran.**

```
slot-retry-count:a: 5
slot-retry-count:b: 0      <-- refused outright
```

On an A/B device the bootloader decrements that counter per failed boot and,
at zero without a `successful` mark, **refuses the slot entirely and falls
back**. InfinityX had been failing to boot on slot b for a while (user
reported Android stalling on a logo), so those retries were almost certainly
burned by InfinityX, not by us.

Consequence: Codex's `fastboot boot` black screen **and** the first
slot-switch reboot both ran against a slot the bootloader was already
declining. Neither tells us anything about the AERA image. **The kernel/DTB
mismatch theory (`cip135-st19` vs `cip131-st15`) remains completely
untested.**

**`qbootctl -s b` does NOT replenish the retry counter** — it only flips the
active flag. The bootloader's own `set_active` does:

```bash
fastboot set_active b     # retry count 0 -> 7
```

Always check `fastboot getvar slot-retry-count:b` before concluding anything
from a failed boot on this device. If it did not decrease, no boot was
attempted.

### Current device state

- `boot_b` holds the AERA image, verified byte-for-byte
  (`f30d437091c67def7212cf8521b36d94ed668972bcf84aff3feea1c06fac37dc`)
- Active slot `b`, retry count replenished to 7
- Slot `a` bootable (retry 5) — EndeavourOS unaffected, SSH returns with it
- **Backups in `aera/backups/`**: `boot_a.img`, `boot_b.img` (InfinityX,
  `dd59cb44…`), `vendor_boot_b.img`, `dtbo_a.img`, `dtbo_b.img` — full
  partition copies, so writing boot_b is reversible. Restore with
  `dd if=backups/boot_b.img of=/dev/disk/by-partlabel/boot_b bs=1M` from EOS.
- `vbmeta_b` was **not** backed up (EOS was unreachable at the time). Do that
  before touching AVB.

### Image structure comparison (measured, not assumed)

| | InfinityX `boot_b` (known to boot) | our AERA image |
|---|---|---|
| header | v3 | v3 |
| bootloader-visible DTB | none (0 FDT hits) | none |
| DTB source | `vendor_boot_b` (3 FDT hits) | same |
| kernel | `4.19.325-cip131-st15` | `4.19.325-cip135-st19` |

Our image is the same *shape* as the one that boots, so it is not obviously
malformed. Note a v3 boot image carries no DTB by design, which is why
`fastboot boot` is a poor test on this device: the bootloader pairs boot with
`vendor_boot`/`dtbo` on a normal boot but not necessarily for a RAM boot.
Prefer flashing `boot_b` (now reversible) over `fastboot boot`.

The notes below are historical; this continuation takes precedence.

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

14. **Never pipe `lunch` — this one cost two wasted builds.** It is a shell
    function, so `lunch ... | tee` runs it in a subshell and everything it
    exports — `TARGET_PRODUCT`, `TARGET_RELEASE`, `TARGET_BUILD_VARIANT` — is
    discarded when that subshell exits. `lunch` itself is fine; it sets all
    three correctly. Redirect to a file instead of piping.

    The two failure modes are very different in how obvious they are:

    - **No `TARGET_RELEASE`** → AOSP falls back to `trunk_staging`
      (`release_config.mk:267`), which this manifest does not ship (it has
      `ap2a`…`bp2a` only), and you get a loud but misleading Go panic:

      ```
      panic: Missing config trunk_staging.  Trace=[trunk_staging]
      build/make/core/release_config.mk:142: error: release-config failed to run.
      ```

    - **No `TARGET_PRODUCT`** → falls back to `aosp_arm64` and **silently
      builds the wrong product**, with no error whatsoever. It happily
      compiled for ~20 minutes before the ninja filename gave it away. **If a
      build looks suspiciously generic, check
      `ls out/soong/build.*.ninja`** — it must say `build.twrp_pipa.ninja`,
      not `build.aosp_arm64.ninja`.

    `build-host/build-aera.sh` now parses all three out of the lunch string,
    exports them, and hard-fails if `TARGET_PRODUCT != twrp_pipa` before
    starting, so the silent case cannot recur.

    Related: `tail -N` on that pipe withholds *all* output until the command
    finishes, so a slow first `dumpvars` looks like a hang.

15. **No `set -u` in any script that sources `envsetup.sh`.** AOSP's shell
    functions read unset variables freely, so nounset kills `lunch` instantly
    with `build/envsetup.sh: line 117: BUILD_VAR_CACHE_READY: unbound variable`.
    Setting `+u` only around the `source` is not enough — `lunch` and `mka` are
    functions *defined* there and run later.

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
