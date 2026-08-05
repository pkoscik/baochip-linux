#!/usr/bin/env python3
"""Pack a raw binary into a UF2 for boot1, or dump an existing UF2.

boot1 writes any UF2 block straight to RRAM if:
    BAREMETAL_START (0x60060000) <= addr < 0x603DA000
    family == 0xa7d76373
and it does NOT check a signature on the write -- signatures are only verified
at boot, on the baremetal/loader slot.  So the XIP kernel can be flashed as a
plain unsigned UF2.  (bao1x-boot/boot1/src/repl.rs, "uf2" command.)

    ./mkuf2.py pack xipImage kernel.uf2 0x600A0000
    ./mkuf2.py dump baremetal.uf2 | head
"""
import struct
import sys

MAGIC0, MAGIC1, MAGIC_END = 0x0A324655, 0x9E5D5157, 0x0AB16F30
FLAG_FAMILY = 0x00002000
FAMILY = 0xA7D76373  # bao1x_api::BAOCHIP_1X_UF2_FAMILY
PAYLOAD = 256  # bytes per block; 476 is the max but 256 is the convention

LOW, HIGH = 0x60060000, 0x603DA000  # boot1's accepted window


def pack(src, dst, addr):
    data = open(src, "rb").read()
    nblocks = (len(data) + PAYLOAD - 1) // PAYLOAD
    end = addr + len(data)
    if addr < LOW or end > HIGH:
        sys.exit(f"error: 0x{addr:08x}..0x{end:08x} outside boot1's window "
                 f"0x{LOW:08x}..0x{HIGH:08x}")
    with open(dst, "wb") as f:
        for i in range(nblocks):
            chunk = data[i * PAYLOAD:(i + 1) * PAYLOAD]
            block = struct.pack("<IIIIIIII", MAGIC0, MAGIC1, FLAG_FAMILY,
                                addr + i * PAYLOAD, len(chunk), i, nblocks, FAMILY)
            block += chunk + b"\0" * (476 - len(chunk))
            block += struct.pack("<I", MAGIC_END)
            assert len(block) == 512
            f.write(block)
    print(f"{dst}: {len(data)} bytes -> {nblocks} blocks, "
          f"0x{addr:08x}..0x{end:08x}")


def dump(path):
    blob = open(path, "rb").read()
    if len(blob) % 512:
        sys.exit("error: not a multiple of 512 bytes")
    lo = hi = None
    for off in range(0, len(blob), 512):
        b = blob[off:off + 512]
        m0, m1, flags, addr, size, blkno, nblk, fam = struct.unpack("<IIIIIIII", b[:32])
        if m0 != MAGIC0 or m1 != MAGIC1:
            sys.exit(f"error: bad magic at block {off // 512}")
        if struct.unpack("<I", b[508:])[0] != MAGIC_END:
            sys.exit(f"error: bad end magic at block {off // 512}")
        lo = addr if lo is None else min(lo, addr)
        hi = max(hi or 0, addr + size)
        if blkno == 0:
            print(f"blocks={nblk} family=0x{fam:08x} "
                  f"{'(bao1x OK)' if fam == FAMILY else '(FOREIGN FAMILY)'}")
    print(f"range 0x{lo:08x}..0x{hi:08x}  "
          f"{'inside' if lo >= LOW and hi <= HIGH else 'OUTSIDE'} boot1 window")


if __name__ == "__main__":
    match sys.argv[1:]:
        case ["pack", src, dst, addr]:
            pack(src, dst, int(addr, 0))
        case ["dump", path]:
            dump(path)
        case _:
            sys.exit(__doc__)
