#!/usr/bin/env python3
"""Split a large raw image into Android sparse files that fastboot can flash.

Host-side fastboot cannot build a sparse image from a file of ~11 GiB on
Windows: it dies with `std::bad_alloc` before transferring anything, whatever
-S chunk size is given. (A 1 GiB file to the same partition works fine.)

This does the conversion itself. Each output file describes the *whole*
partition but marks everything outside its own slice as DONT_CARE, so flashing
them in order writes the image piece by piece:

    fastboot flash linux chunk.000.simg
    fastboot flash linux chunk.001.simg
    ...

A slice that is entirely zero becomes a FILL chunk, so nothing is transferred
for it and the device zeroes the range itself.

Sparse format reference: AOSP system/core/libsparse/sparse_format.h
"""

from __future__ import annotations

import argparse
import os
import struct
import sys

SPARSE_MAGIC = 0xED26FF3A
FILE_HDR_SZ = 28
CHUNK_HDR_SZ = 12

CHUNK_RAW = 0xCAC1
CHUNK_FILL = 0xCAC2
CHUNK_DONT_CARE = 0xCAC3


def file_header(block_size: int, total_blocks: int, total_chunks: int) -> bytes:
    return struct.pack(
        "<IHHHHIIII",
        SPARSE_MAGIC,
        1,              # major version
        0,              # minor version
        FILE_HDR_SZ,
        CHUNK_HDR_SZ,
        block_size,
        total_blocks,   # size of the whole partition image, in blocks
        total_chunks,
        0,              # image checksum, unused
    )


def chunk_header(chunk_type: int, blocks: int, payload: int) -> bytes:
    return struct.pack(
        "<HHII", chunk_type, 0, blocks, CHUNK_HDR_SZ + payload
    )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image", help="raw image to split")
    ap.add_argument("outdir", help="directory to write chunk.NNN.simg into")
    ap.add_argument("--slice-mib", type=int, default=256,
                    help="payload per output file, in MiB (default 256)")
    ap.add_argument("--block-size", type=int, default=4096,
                    help="sparse block size (default 4096)")
    args = ap.parse_args()

    block_size = args.block_size
    if block_size % 4:
        print("block size must be a multiple of 4", file=sys.stderr)
        return 2

    slice_bytes = args.slice_mib * 1024 * 1024
    if slice_bytes % block_size:
        print("--slice-mib must be a whole number of blocks", file=sys.stderr)
        return 2
    slice_blocks = slice_bytes // block_size

    size = os.path.getsize(args.image)
    # A trailing partial block still has to be written, so round up.
    total_blocks = (size + block_size - 1) // block_size
    if total_blocks > 0xFFFFFFFF:
        print("image too large for the sparse format", file=sys.stderr)
        return 2

    os.makedirs(args.outdir, exist_ok=True)

    zero_block = bytes(block_size)
    written = []
    index = 0

    with open(args.image, "rb") as src:
        start_block = 0
        while start_block < total_blocks:
            blocks = min(slice_blocks, total_blocks - start_block)
            src.seek(start_block * block_size)
            payload = src.read(blocks * block_size)
            # The final slice may be short of a whole block; pad it.
            if len(payload) < blocks * block_size:
                payload += bytes(blocks * block_size - len(payload))

            lead = start_block
            trail = total_blocks - start_block - blocks
            all_zero = payload.count(0) == len(payload)

            name = os.path.join(args.outdir, f"chunk.{index:03d}.simg")
            with open(name, "wb") as out:
                chunks = (1 if lead else 0) + 1 + (1 if trail else 0)
                out.write(file_header(block_size, total_blocks, chunks))
                if lead:
                    out.write(chunk_header(CHUNK_DONT_CARE, lead, 0))
                if all_zero:
                    # Nothing to transfer: tell the device to fill with zeros.
                    out.write(chunk_header(CHUNK_FILL, blocks, 4))
                    out.write(struct.pack("<I", 0))
                else:
                    out.write(chunk_header(CHUNK_RAW, blocks, len(payload)))
                    out.write(payload)
                if trail:
                    out.write(chunk_header(CHUNK_DONT_CARE, trail, 0))

            written.append((name, all_zero, os.path.getsize(name)))
            kind = "zero-fill" if all_zero else "data"
            print(f"  {os.path.basename(name)}  blocks {start_block}..."
                  f"{start_block + blocks - 1}  {kind}  "
                  f"{os.path.getsize(name) / (1024 * 1024):.1f} MiB")

            start_block += blocks
            index += 1

    total_out = sum(s for _, _, s in written)
    zero_files = sum(1 for _, z, _ in written if z)
    print()
    print(f"image           {size:,} bytes ({total_blocks:,} blocks of {block_size})")
    print(f"output          {len(written)} files, {total_out:,} bytes total")
    print(f"zero-fill files {zero_files} (no data transferred for these)")
    print()
    print("Flash in order, e.g.:")
    print("  for f in chunk.*.simg; do fastboot flash linux \"$f\" || break; done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
