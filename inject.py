#!/usr/bin/env python3
"""
inject.py — Inject IAPCrack.dylib into a decrypted IPA
Patches the Mach-O load commands and copies the dylib into the bundle.
Works on macOS / Linux / Windows (Python 3.7+).
"""

import struct
import sys
import shutil
import zipfile
import os
from pathlib import Path

# ── Mach-O constants ──────────────────────────────────────────
MH_MAGIC_64    = 0xFEEDFACF
LC_LOAD_DYLIB  = 0xC
LC_REEXPORT_DYLIB = (0x80000000 | 0xC)
LC_CODE_SIGNATURE = 0x1D

UINT64 = struct.Struct("<Q")
UINT32 = struct.Struct("<I")


def pad8(size: int) -> int:
    return (size + 7) & ~7


def patch_macho(binary_path: str, dylib_path: str) -> bool:
    """Insert LC_LOAD_DYLIB pointing to dylib_path into the Mach-O binary."""
    with open(binary_path, "rb") as f:
        data = bytearray(f.read())

    # Parse fat header
    fat_magic = struct.unpack_from(">I", data, 0)[0]
    offset = 0

    if fat_magic == 0xCAFEBABE:  # FAT binary
        nfat = struct.unpack_from(">I", data, 4)[0]
        print(f"  FAT binary, {nfat} arches")
        # Find arm64 slice
        for i in range(nfat):
            cpu = struct.unpack_from(">I", data, 8 + i * 20)[0]
            sub = struct.unpack_from(">I", data, 8 + i * 20 + 4)[0]
            off = struct.unpack_from(">I", data, 8 + i * 20 + 8)[0]
            sz  = struct.unpack_from(">I", data, 8 + i * 20 + 12)[0]
            print(f"    cpu={cpu:#x} sub={sub:#x} offset={off} size={sz}")
            if cpu == 0x100000C:  # arm64 (CPU_TYPE_ARM64)
                offset = off
                print(f"  → patching arm64 slice at offset {offset}")
                # Patch the fat entry to update size later
                fat_entry_base = 8 + i * 20
                break
        else:
            # Try CPU_TYPE_ARM64_32 or any arm64
            for i in range(nfat):
                cpu = struct.unpack_from(">I", data, 8 + i * 20)[0]
                if cpu in (0x100000C, 0x200000C, 0x1000007):  # arm64, arm64_32, x86_64
                    offset = struct.unpack_from(">I", data, 8 + i * 20 + 8)[0]
                    fat_entry_base = 8 + i * 20
                    print(f"  → patching arch {cpu:#x} at offset {offset}")
                    break
            else:
                print("  ✗ no arm64 slice found in FAT binary")
                return False

    # Verify Mach-O 64 magic
    magic = struct.unpack_from("<I", data, offset)[0]
    if magic != MH_MAGIC_64:
        print(f"  ✗ not a Mach-O 64 binary (magic={magic:#x})")
        return False

    hdr_sz = 32  # mach_header_64
    ncmds    = struct.unpack_from("<I", data, offset + 16)[0]
    sizecmds = struct.unpack_from("<I", data, offset + 20)[0]

    print(f"  ncmds={ncmds}, sizeofcmds={sizecmds}")

    # Check if dylib already injected
    cmd_ptr = offset + hdr_sz
    path_bytes = dylib_path.encode("utf-8") + b"\x00"
    for _ in range(ncmds):
        cmd = struct.unpack_from("<I", data, cmd_ptr)[0]
        cmd_size = struct.unpack_from("<I", data, cmd_ptr + 4)[0]
        if cmd in (LC_LOAD_DYLIB, LC_REEXPORT_DYLIB):
            name_off = struct.unpack_from("<I", data, cmd_ptr + 8)[0]
            name = data[cmd_ptr + name_off:].split(b"\x00")[0].decode("utf-8", errors="replace")
            if dylib_path in name or "IAPCrack" in name:
                print(f"  ⚠ dylib already injected: {name}")
                return True
        cmd_ptr += cmd_size

    # Prepare the new LC_LOAD_DYLIB command
    dylib_cmd = struct.Struct("<III")  # cmd, cmdsize, name_offset
    name_offset = dylib_cmd.size + 8  # after dylib_command + timestamp + version fields
    # dylib_command has: cmd(4), cmdsize(4), name.offset(4), timestamp(4), current_version(4), compatibility_version(4)
    cmd_total = struct.Struct("<I I I I I I")
    # Build the dylib command
    name_pad_len = ((len(path_bytes) + 7) & ~7) - len(path_bytes)
    total_cmd_size = cmd_total.size + len(path_bytes) + name_pad_len

    new_cmd = cmd_total.pack(
        LC_LOAD_DYLIB,
        total_cmd_size,
        cmd_total.size,  # name offset
        2,               # timestamp
        0x00010000,      # current_version = 1.0
        0x00010000,      # compatibility_version = 1.0
    )
    new_cmd += path_bytes
    new_cmd += b"\x00" * name_pad_len

    # Insert the new load command before LC_CODE_SIGNATURE (must be last)
    # Find LC_CODE_SIGNATURE position
    insert_pos = None
    cmd_ptr = offset + hdr_sz
    for _ in range(ncmds):
        cmd = struct.unpack_from("<I", data, cmd_ptr)[0]
        cmd_size = struct.unpack_from("<I", data, cmd_ptr + 4)[0]
        if cmd == LC_CODE_SIGNATURE:
            insert_pos = cmd_ptr
            break
        cmd_ptr += cmd_size

    if insert_pos is None:
        # Insert at end of load commands
        insert_pos = offset + hdr_sz + sizecmds

    # Insert the new command
    data[insert_pos:insert_pos] = bytearray(new_cmd)

    # Update ncmds and sizeofcmds
    new_ncmds = ncmds + 1
    new_sizecmds = sizecmds + total_cmd_size
    struct.pack_into("<I", data, offset + 16, new_ncmds)
    struct.pack_into("<I", data, offset + 20, new_sizecmds)

    # Update FAT header if needed
    if fat_magic == 0xCAFEBABE:
        # Update the slice size in the fat header
        old_size = struct.unpack_from(">I", data, fat_entry_base + 12)[0]
        new_size = old_size + total_cmd_size
        struct.pack_into(">I", data, fat_entry_base + 12, new_size)

    # Write back
    with open(binary_path, "wb") as f:
        f.write(data)

    print(f"  ✓ injected LC_LOAD_DYLIB: {dylib_path}")
    print(f"    ncmds: {ncmds} → {new_ncmds}, sizeofcmds: {sizecmds} → {new_sizecmds}")
    return True


def inject_ipa(ipa_path: str, dylib_path: str, output_path: str):
    """Inject dylib into IPA."""
    work_dir = Path(ipa_path).parent / "_inject_work"
    if work_dir.exists():
        shutil.rmtree(work_dir)
    work_dir.mkdir()

    print(f"[1/4] Extracting IPA...")
    with zipfile.ZipFile(ipa_path, "r") as zf:
        zf.extractall(work_dir)

    # Find Payload/*.app
    payload_dir = work_dir / "Payload"
    app_dirs = list(payload_dir.glob("*.app"))
    if not app_dirs:
        print("  ✗ no .app found in Payload/")
        return False
    app_dir = app_dirs[0]
    print(f"  app: {app_dir.name}")

    # Find the binary (matching CFBundleExecutable)
    # Read Info.plist
    info_plist = app_dir / "Info.plist"
    import plistlib
    with open(info_plist, "rb") as f:
        plist = plistlib.load(f)
    executable = plist.get("CFBundleExecutable", app_dir.stem)
    binary_path = app_dir / executable
    if not binary_path.exists():
        # Fall back to searching
        for f in app_dir.iterdir():
            if f.is_file() and f.suffix == "" and f.name != "PkgInfo":
                if f.stat().st_size > 100000:
                    binary_path = f
                    break

    print(f"  binary: {binary_path.name} ({binary_path.stat().st_size:,} bytes)")

    # Copy dylib into Frameworks/
    print(f"[2/4] Copying dylib to bundle...")
    frameworks_dir = app_dir / "Frameworks"
    frameworks_dir.mkdir(exist_ok=True)
    dylib_dest = frameworks_dir / os.path.basename(dylib_path)
    rel_path = f"@executable_path/Frameworks/{os.path.basename(dylib_path)}"
    shutil.copy2(dylib_path, dylib_dest)
    print(f"  → {rel_path}")

    # Patch Mach-O
    print(f"[3/4] Patching Mach-O load commands...")
    if not patch_macho(str(binary_path), rel_path):
        print("  ✗ Mach-O patching failed")
        return False

    # Re-pack IPA
    print(f"[4/4] Re-packaging IPA...")
    output_path = Path(output_path)
    if output_path.exists():
        output_path.unlink()

    with zipfile.ZipFile(output_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for root, _, files in os.walk(work_dir):
            for name in files:
                file_path = Path(root) / name
                arcname = str(file_path.relative_to(work_dir))
                zf.write(file_path, arcname)

    shutil.rmtree(work_dir)
    print(f"  ✓ {output_path} ({output_path.stat().st_size:,} bytes)")
    print(f"\nDone. Install the patched IPA with LiveContainer.")
    return True


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print(f"Usage: python {sys.argv[0]} <input.ipa> <IAPCrack.dylib> <output.ipa>")
        sys.exit(1)

    inject_ipa(sys.argv[1], sys.argv[2], sys.argv[3])
