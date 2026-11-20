#!/usr/bin/env python3
"""Turns off spotifyglass's own sound engine so JamesDSP (SpotCloud) is the only one processing.

spotifyglass keeps its Audio effects page, presets, AutoEq and file pickers; they keep writing the
spotifyglass.dsp.* preferences, which SpotCloud's JamesDSP engine reads. Only the built-in engine's
render entry point, SGDSPEngineProcess(engine, left, right, frames), is changed to return at once:
it processes in place, so returning leaves the sound untouched.

The patch is checked against the exact build the user attached (sha256 below) and refuses anything else.
Usage: patch_spotifyglass.py <spotifyglass.dylib in> <out>
"""
import hashlib, struct, sys

EXPECTED_SHA256 = "94e622a456463dc33488f04572f7e35b4f12c30cd9aa7918cfb4d07ab0344632"
SYMBOL = b"_SGDSPEngineProcess"
EXPECTED_PROLOGUE = bytes.fromhex("ff4303d1")  # sub sp, sp, #0xd0
RET = struct.pack("<I", 0xD65F03C0)


def symbol_vmaddr(data: bytes, name: bytes) -> int:
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == 0x2:  # LC_SYMTAB
            symoff, nsyms, stroff, _ = struct.unpack_from("<IIII", data, off + 8)
            for i in range(nsyms):
                strx, ntype, _, _, value = struct.unpack_from("<IBBHQ", data, symoff + i * 16)
                end = data.index(b"\0", stroff + strx)
                if data[stroff + strx:end] == name and ntype & 0x0E == 0x0E:
                    return value
        off += size
    raise SystemExit(f"{name.decode()} not found")


def vm_to_file(data: bytes, vmaddr: int) -> int:
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == 0x19:  # LC_SEGMENT_64
            seg_vm, seg_vmsize, seg_fileoff, seg_filesize = struct.unpack_from("<QQQQ", data, off + 24)
            if seg_vm <= vmaddr < seg_vm + seg_filesize:
                return seg_fileoff + (vmaddr - seg_vm)
        off += size
    raise SystemExit(f"0x{vmaddr:x} is in no segment")


def main() -> None:
    src, dst = sys.argv[1], sys.argv[2]
    data = bytearray(open(src, "rb").read())
    digest = hashlib.sha256(data).hexdigest()
    if digest != EXPECTED_SHA256:
        raise SystemExit(f"unexpected spotifyglass.dylib (sha256 {digest}); this patch is for {EXPECTED_SHA256}")
    if struct.unpack_from("<I", data, 0)[0] != 0xFEEDFACF:
        raise SystemExit("not a thin arm64 Mach-O")
    at = vm_to_file(data, symbol_vmaddr(data, SYMBOL))
    if data[at:at + 4] != EXPECTED_PROLOGUE:
        raise SystemExit(f"unexpected prologue {data[at:at + 4].hex()} at 0x{at:x}")
    data[at:at + 4] = RET
    open(dst, "wb").write(data)
    print(f"patched {SYMBOL.decode()} at file offset 0x{at:x}; sha256 {hashlib.sha256(data).hexdigest()}")


if __name__ == "__main__":
    main()
