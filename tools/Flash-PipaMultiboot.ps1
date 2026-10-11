<#
.SYNOPSIS
    Flash the EndeavourOS pipa multiboot image from Windows, without disturbing
    the Android install on the other A/B slot.

.DESCRIPTION
    Upstream ships flash-multiboot.sh, which is bash-only and offers to erase
    "dtbo_ab" -- and the _ab suffix means BOTH slots. On a device whose Android
    lives on one slot that erases Android's dtbo too. This script picks the slot
    Android is NOT using and touches only that slot's dtbo and vbmeta.

    Xiaomi Pad 6 is a Virtual A/B device: only one slot has logical partitions
    in `super`, so the other slot is free for the UEFI + Linux boot chain.

.PARAMETER ImageDir
    Directory holding the extracted release zip (silicium.img,
    endeavouros_esp.raw, endeavouros_boot.raw, endeavouros_rootfs.raw).

.PARAMETER RootfsPartition
    GPT partition to receive the rootfs. Default 'linux'.

.PARAMETER FlashVbmeta
    Also flash the verity-disabled vbmeta to the target slot only.

.PARAMETER SwitchTo
    Don't flash anything; just set the active slot. 'linux' or 'android'.

.EXAMPLE
    .\Flash-PipaMultiboot.ps1 -ImageDir .\endeavouros-pipa-plasma-20261011 -WhatIf
.EXAMPLE
    .\Flash-PipaMultiboot.ps1 -ImageDir .\endeavouros-pipa-plasma-20261011
.EXAMPLE
    .\Flash-PipaMultiboot.ps1 -SwitchTo android
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $ImageDir,
    [string] $RootfsPartition = 'linux',
    [switch] $FlashVbmeta,
    [ValidateSet('linux', 'android')] [string] $SwitchTo,
    [string] $Fastboot = 'fastboot',
    # Host-side fastboot dies with std::bad_alloc building a sparse image from
    # the ~11 GiB rootfs on Windows, whatever -S it is given, so images above
    # this threshold are split with tools/split-sparse.py instead.
    [int] $SplitAboveGiB = 4,
    [int] $SparseSliceMiB = 256
)

$ErrorActionPreference = 'Stop'

# Stock pipa partitions the project repurposes for the Linux boot chain.
# Both are unslotted, unmounted and unused by Android (cust is a leftover
# Xiaomi ext4 preload volume; rawdump holds crash dumps).
$EspPartition  = 'rawdump'
$BootPartition = 'cust'

function Invoke-Fastboot {
    param([Parameter(ValueFromRemainingArguments)] [string[]] $FbArgs)
    Write-Host "  fastboot $($FbArgs -join ' ')" -ForegroundColor DarkGray
    $out = & $Fastboot @FbArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        $out | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        throw "fastboot $($FbArgs -join ' ') failed with exit code $LASTEXITCODE"
    }
    return $out
}

function Get-FastbootVar {
    param([string] $Name)
    $out = & $Fastboot getvar $Name 2>&1
    # fastboot prints "name: value" on stderr; take the first match.
    $line = $out | Where-Object { $_ -match "^$([regex]::Escape($Name)):\s*(.+)$" } | Select-Object -First 1
    if (-not $line) { return $null }
    return ($line -replace "^$([regex]::Escape($Name)):\s*", '').Trim()
}

if (-not (Get-Command $Fastboot -ErrorAction SilentlyContinue)) {
    throw "fastboot not found on PATH. Pass -Fastboot 'C:\path\to\fastboot.exe'."
}

Write-Host '### Verifying connected device' -ForegroundColor Cyan
$product = Get-FastbootVar 'product'
if (-not $product) {
    throw 'No device answered in fastboot mode. Reboot to the bootloader first (adb reboot bootloader).'
}
Write-Host "  product: $product"
if ($product -notmatch 'pipa') {
    throw "Connected device reports '$product', not pipa. Refusing to flash."
}

$currentSlot = Get-FastbootVar 'current-slot'
if ($currentSlot -notin @('a', 'b')) {
    throw "Could not determine the current slot (got '$currentSlot')."
}
# Android keeps the slot it is on now; Linux goes to the other one.
$androidSlot = $currentSlot
$linuxSlot   = if ($currentSlot -eq 'a') { 'b' } else { 'a' }

Write-Host "  Android slot: _$androidSlot   ->  Linux will use slot: _$linuxSlot"

# --- slot switch only -------------------------------------------------------
if ($SwitchTo) {
    $target = if ($SwitchTo -eq 'linux') { $linuxSlot } else { $androidSlot }
    Write-Host ''
    Write-Host "### Setting active slot to _$target ($SwitchTo)" -ForegroundColor Cyan
    Write-Warning "Note: 'android' here means the slot currently active ($androidSlot). If you are already booted into Linux, that mapping is inverted - pass the slot you want explicitly by re-running from Android, or use: fastboot set_active a|b"
    if ($PSCmdlet.ShouldProcess("slot _$target", 'fastboot set_active')) {
        Invoke-Fastboot set_active $target | Out-Null
        Invoke-Fastboot reboot | Out-Null
        Write-Host 'Done. Device rebooting.' -ForegroundColor Green
    }
    return
}

# --- full flash -------------------------------------------------------------
if (-not $ImageDir) { throw 'Specify -ImageDir (the extracted release zip), or use -SwitchTo.' }
$ImageDir = (Resolve-Path -LiteralPath $ImageDir).Path

$files = [ordered]@{
    Silicium = Join-Path $ImageDir 'silicium.img'
    Esp      = Join-Path $ImageDir 'endeavouros_esp.raw'
    Boot     = Join-Path $ImageDir 'endeavouros_boot.raw'
    Rootfs   = Join-Path $ImageDir 'endeavouros_rootfs.raw'
}
if ($FlashVbmeta) { $files.Vbmeta = Join-Path $ImageDir 'vbmeta.img' }

Write-Host ''
Write-Host '### Checking image files' -ForegroundColor Cyan
foreach ($kv in $files.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $kv.Value)) { throw "Missing image file: $($kv.Value)" }
    $mb = [math]::Round((Get-Item -LiteralPath $kv.Value).Length / 1MB, 1)
    Write-Host ("  {0,-9} {1,10:N1} MB  {2}" -f $kv.Key, $mb, (Split-Path $kv.Value -Leaf))
}

# Verify checksums if the release shipped them.
$sumFile = Join-Path $ImageDir 'SHA256SUMS'
if (Test-Path -LiteralPath $sumFile) {
    Write-Host ''
    Write-Host '### Verifying SHA256SUMS' -ForegroundColor Cyan
    $bad = 0
    foreach ($line in Get-Content -LiteralPath $sumFile) {
        if ($line -notmatch '^([0-9a-fA-F]{64})\s+\*?(.+)$') { continue }
        $expected = $Matches[1]; $name = $Matches[2].Trim()
        $path = Join-Path $ImageDir $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($actual -ieq $expected) {
            Write-Host "  OK   $name"
        } else {
            Write-Host "  BAD  $name" -ForegroundColor Red
            $bad++
        }
    }
    if ($bad -gt 0) { throw "$bad file(s) failed checksum verification. Re-download." }
} else {
    Write-Warning 'No SHA256SUMS in the image directory; skipping checksum verification.'
}

# The rootfs partition must exist and be big enough, or fastboot fails midway.
Write-Host ''
Write-Host '### Checking target partitions' -ForegroundColor Cyan
foreach ($p in @($RootfsPartition, $EspPartition, $BootPartition)) {
    $raw = Get-FastbootVar "partition-size:$p"
    if (-not $raw) {
        if ($p -eq $RootfsPartition) {
            throw "Partition '$p' does not exist. Run tools/repartition-pipa.sh from recovery first."
        }
        Write-Warning "  could not read size of '$p'"
        continue
    }
    $bytes = [Convert]::ToUInt64(($raw -replace '^0x', ''), 16)
    Write-Host ("  {0,-8} {1,10:N1} MiB" -f $p, ($bytes / 1MB))

    $needFile = switch ($p) {
        $RootfsPartition { $files.Rootfs }
        $EspPartition    { $files.Esp }
        $BootPartition   { $files.Boot }
    }
    $needBytes = (Get-Item -LiteralPath $needFile).Length
    if ($bytes -lt $needBytes) {
        throw ("Partition '{0}' is {1:N1} MiB but the image needs {2:N1} MiB." -f $p, ($bytes / 1MB), ($needBytes / 1MB))
    }
}

Write-Host ''
Write-Host '### Flash plan' -ForegroundColor Cyan
Write-Host "  silicium.img            -> boot_$linuxSlot"
Write-Host "  erase dtbo              -> dtbo_$linuxSlot   (dtbo_$androidSlot left alone)"
if ($FlashVbmeta) { Write-Host "  vbmeta.img              -> vbmeta_$linuxSlot (vbmeta_$androidSlot left alone)" }
Write-Host "  endeavouros_esp.raw     -> $EspPartition"
Write-Host "  endeavouros_boot.raw    -> $BootPartition"
Write-Host "  endeavouros_rootfs.raw  -> $RootfsPartition"
Write-Host "  set_active              -> $linuxSlot"
Write-Host ''
Write-Host "  Android on slot _$androidSlot is not modified. Switch back with:" -ForegroundColor Yellow
Write-Host "    fastboot set_active $androidSlot" -ForegroundColor Yellow

if (-not $PSCmdlet.ShouldProcess("Xiaomi Pad 6 ($product), slot _$linuxSlot", 'Flash EndeavourOS multiboot')) {
    Write-Host ''
    Write-Host 'Nothing flashed (-WhatIf).' -ForegroundColor Green
    return
}

Write-Host ''
Write-Host "### Erasing dtbo_$linuxSlot" -ForegroundColor Cyan
Invoke-Fastboot erase "dtbo_$linuxSlot" | Out-Null

if ($FlashVbmeta) {
    Write-Host "### Flashing vbmeta_$linuxSlot" -ForegroundColor Cyan
    Invoke-Fastboot flash "vbmeta_$linuxSlot" $files.Vbmeta | Out-Null
}

Write-Host "### Flashing Mu-Silicium UEFI to boot_$linuxSlot" -ForegroundColor Cyan
Invoke-Fastboot flash "boot_$linuxSlot" $files.Silicium | Out-Null

Write-Host "### Flashing EFI system partition to $EspPartition" -ForegroundColor Cyan
Invoke-Fastboot flash $EspPartition $files.Esp | Out-Null

Write-Host "### Flashing /boot to $BootPartition" -ForegroundColor Cyan
Invoke-Fastboot flash $BootPartition $files.Boot | Out-Null

Write-Host "### Flashing rootfs to $RootfsPartition (this is the slow one)" -ForegroundColor Cyan
$rootfsBytes = (Get-Item -LiteralPath $files.Rootfs).Length
if ($rootfsBytes -gt ($SplitAboveGiB * 1GB)) {
    # fastboot cannot sparse this itself; pre-split it.
    $splitter = Join-Path $PSScriptRoot 'split-sparse.py'
    if (-not (Test-Path -LiteralPath $splitter)) { throw "split-sparse.py not found beside this script." }
    $py = (Get-Command python -ErrorAction SilentlyContinue) ?? (Get-Command python3 -ErrorAction SilentlyContinue)
    if (-not $py) { throw 'python is required to split images larger than the fastboot limit.' }

    $sparseDir = Join-Path ([System.IO.Path]::GetTempPath()) ("pipa-sparse-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    Write-Host ("  image is {0:N1} GiB; pre-splitting into {1} MiB sparse slices" -f ($rootfsBytes / 1GB), $SparseSliceMiB)
    & $py.Source -I $splitter $files.Rootfs $sparseDir --slice-mib $SparseSliceMiB | Select-Object -Last 5
    if ($LASTEXITCODE -ne 0) { throw "split-sparse.py failed with exit code $LASTEXITCODE" }

    try {
        $chunks = Get-ChildItem (Join-Path $sparseDir 'chunk.*.simg') | Sort-Object Name
        if (-not $chunks) { throw "splitter produced no chunks in $sparseDir" }
        $i = 0
        foreach ($chunk in $chunks) {
            $i++
            Write-Host ("  [{0}/{1}] {2}" -f $i, $chunks.Count, $chunk.Name)
            Invoke-Fastboot flash $RootfsPartition $chunk.FullName | Out-Null
        }
    } finally {
        Remove-Item -LiteralPath $sparseDir -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Invoke-Fastboot flash $RootfsPartition $files.Rootfs | Out-Null
}

Write-Host "### Setting active slot to _$linuxSlot" -ForegroundColor Cyan
Invoke-Fastboot set_active $linuxSlot | Out-Null

Write-Host ''
Write-Host 'Done. Rebooting into EndeavourOS.' -ForegroundColor Green
Write-Host "First boot resizes the rootfs and runs setup; it can take a few minutes." -ForegroundColor Green
Invoke-Fastboot reboot | Out-Null
