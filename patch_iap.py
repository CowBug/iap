#!/usr/bin/env python3
"""
patch_iap.py — Static binary patch: bypass IAP checks in UltraPod
Searches for StoreKit purchase verification code paths and patches them
to always return "purchased" state without needing a dylib injection.
"""

import struct
import sys
import os
from pathlib import Path


# ── Known product IDs to search for ───────────────────────────
PRODUCT_IDS = [
    b"com.maxpod.pro_lifetime",
    b"com.maxpod.ultimate_lifetime",
    b"com.maxpod.ultimate_upgrade_from_pro",
]

# Key strings near purchase logic
PURCHASE_STRINGS = [
    b"PurchaseServiceProtocol",
    b"StoreKitPurchaseService",
    b"verified_product_ids",
    b"currentEntitlements",
    b"purchaseTier",
    b"unlockedUltimate",
]


def find_all_bytes(data: bytes, pattern: bytes) -> list[int]:
    """Return all offsets where pattern appears."""
    offsets = []
    pos = 0
    while True:
        idx = data.find(pattern, pos)
        if idx == -1:
            break
        offsets.append(idx)
        pos = idx + 1
    return offsets


def unsign_binary(binary_path: str):
    """Strip LC_CODE_SIGNATURE to allow patching."""
    with open(binary_path, "rb") as f:
        data = bytearray(f.read())

    MH_MAGIC_64 = 0xFEEDFACF
    LC_CODE_SIGNATURE = 0x1D
    FAT_MAGIC = 0xCAFEBABE

    magic = struct.unpack_from("<I", data, 0)[0]
    offset = 0

    if magic == FAT_MAGIC:
        print("  FAT binary — unsigning arm64 slice...")
        nfat = struct.unpack_from(">I", data, 4)[0]
        for i in range(nfat):
            cpu = struct.unpack_from(">I", data, 8 + i * 20)[0]
            if cpu == 0x100000C:  # arm64
                offset = struct.unpack_from(">I", data, 8 + i * 20 + 8)[0]
                magic = struct.unpack_from("<I", data, offset)[0]
                break
        else:
            offset = 0
            magic = struct.unpack_from("<I", data, 0)[0]

    if magic != MH_MAGIC_64:
        print(f"  ✗ not arm64 Mach-O (magic={magic:#x})")
        return False

    hdr_sz = 32
    ncmds = struct.unpack_from("<I", data, offset + 16)[0]
    sizecmds = struct.unpack_from("<I", data, offset + 20)[0]

    cmd_ptr = offset + hdr_sz
    lc_code_sig_off = None
    lc_code_sig_size = None
    for _ in range(ncmds):
        cmd = struct.unpack_from("<I", data, cmd_ptr)[0]
        cmd_size = struct.unpack_from("<I", data, cmd_ptr + 4)[0]
        if cmd == LC_CODE_SIGNATURE:
            lc_code_sig_off = cmd_ptr
            lc_code_sig_size = cmd_size
            break
        cmd_ptr += cmd_size

    if lc_code_sig_off is not None:
        # Remove the LC_CODE_SIGNATURE command and its data
        data_off = struct.unpack_from("<I", data, lc_code_sig_off + 8)[0]
        data_sz  = struct.unpack_from("<I", data, lc_code_sig_off + 12)[0]
        print(f"  stripping LC_CODE_SIGNATURE (data_off={data_off:#x}, data_sz={data_sz})")
        # Remove the load command
        end_of_lcs = offset + hdr_sz + sizecmds
        # Shift everything after lc_code_sig_off backward
        # Just zero out and reduce ncmds/sizeofcmds
        data[lc_code_sig_off:lc_code_sig_off + lc_code_sig_size] = b"\x00" * lc_code_sig_size
        struct.pack_into("<I", data, offset + 16, ncmds - 1)
        struct.pack_into("<I", data, offset + 20, sizecmds - lc_code_sig_size)
        print("  ✓ code signature removed")

    with open(binary_path, "wb") as f:
        f.write(data)
    return True


def find_product_id_check_offsets(data: bytes) -> list[dict]:
    """Find ARM64 assembly patterns that load product ID strings."""
    results = []
    # ARM64: ADRP + ADD pattern loading a string address
    # We look for references to the product ID strings in the __TEXT,__cstring section

    print("  Searching for product ID string references...")
    for pid in PRODUCT_IDS:
        offsets = find_all_bytes(data, pid)
        print(f"    {pid.decode()}: found at {len(offsets)} locations")

        for off in offsets:
            # The string is in __TEXT,__cstring
            # Instructions referencing it will use PC-relative addressing (ADRP/ADR)
            # Search backwards in __TEXT,__text for ADRP with this page offset
            results.append({
                "product_id": pid,
                "string_offset": off,
            })

    return results


def find_entitlement_check(data: bytes) -> list[int]:
    """Look for Transaction.currentEntitlements usage patterns."""
    # Search for the mangled Swift symbol reference
    sym = b"_$s8StoreKit11TransactionV19currentEntitlements"
    return find_all_bytes(data, sym)


def patch_arm64_conditional(data: bytearray, offset: int, always_take: bool = True):
    """
    Patch an ARM64 conditional branch to always/never branch.
    At offset, there should be a conditional branch instruction (B.cond).
    We replace it with B (unconditional branch) or NOP.
    """
    insn = struct.unpack_from("<I", data, offset)[0]
    opcode = insn >> 24

    # B.cond: opcode == 0x54 (32-bit conditional branch)
    if (opcode & 0xFE) == 0x54:
        if always_take:
            # Convert to B (unconditional): 0x14xxxxx -> B
            # Extract the immediate offset from the B.cond
            imm19 = (insn >> 5) & 0x7FFFF
            new_insn = 0x14000000 | imm19
        else:
            # NOP
            new_insn = 0xD503201F
        struct.pack_into("<I", data, offset, new_insn)
        return True

    # CBZ/CBNZ: opcode == 0xB4 or 0xB5 (32-bit compare and branch)
    if (opcode & 0xFE) == 0xB4:
        if always_take:
            # Convert to B: extract imm19
            imm19 = (insn >> 5) & 0x7FFFF
            new_insn = 0x14000000 | imm19
        else:
            new_insn = 0xD503201F
        struct.pack_into("<I", data, offset, new_insn)
        return True

    # TBZ/TBNZ: opcode == 0x36 or 0x37
    if (opcode & 0xFE) == 0x36:
        if always_take:
            imm14 = (insn >> 5) & 0x3FFF
            new_insn = 0x14000000 | imm14
        else:
            new_insn = 0xD503201F
        struct.pack_into("<I", data, offset, new_insn)
        return True

    return False


def patch_arm64_return_true(data: bytearray, offset: int):
    """
    At the given offset, replace instructions to make the function
    return true (ARM64: MOV W0, #1; RET).
    """
    mov_w0_1 = 0x52800020  # MOV W0, #1
    ret      = 0xD65F03C0  # RET
    struct.pack_into("<I", data, offset, mov_w0_1)
    struct.pack_into("<I", data, offset + 4, ret)
    print(f"  ✓ patched function at {offset:#x} → return true")


def scan_for_func_prologue(data: bytes, start: int, window: int = 0x1000) -> list[int]:
    """
    Scan for ARM64 function prologues near a given offset.
    Typical prologue: STP x29, x30, [sp, #-N]! / MOV x29, sp
    Pattern: 0xA9BF... followed by 0x910003FD or 0xD10043FF
    """
    results = []
    begin = max(0, start - window)
    end = min(len(data), start + window)
    for i in range(begin, end - 4, 4):
        insn = struct.unpack_from("<I", data, i)[0]
        # STP x29, x30, [sp, #imm]! (pre-indexed)
        if (insn & 0xFFC00000) == 0xA9800000:
            # Check next instruction for MOV x29, sp (0x910003FD)
            next_insn = struct.unpack_from("<I", data, i + 4)[0]
            if next_insn == 0x910003FD:
                results.append(i)
    return results


def find_isPro_check(data: bytes) -> int | None:
    """Find the 'isPro' check function by searching for references."""
    # The key property name
    for s in [b"isPro", b"unlockedUltimate", b"purchaseTier"]:
        offsets = find_all_bytes(data, s)
        if offsets:
            print(f"  '{s.decode()}' found at {len(offsets)} location(s)")
            for off in offsets:
                # This is in __TEXT,__cstring or somewhere nearby
                # Find nearby function prologues that might reference this
                funcs = scan_for_func_prologue(data, off)
                if funcs:
                    print(f"    nearby function prologue at: {[hex(f) for f in funcs]}")
                    return funcs[0]
    return None


def patch_binary(input_path: str, output_path: str):
    """Main patching logic."""
    print(f"Loading binary: {input_path}")
    with open(input_path, "rb") as f:
        data = bytearray(f.read())

    print(f"Binary size: {len(data):,} bytes")

    # 1. Strip code signature (so we can modify)
    unsign_binary(input_path)
    # Reload
    with open(input_path, "rb") as f:
        data = bytearray(f.read())

    # 2. Find purchase-related code paths
    find_product_id_check_offsets(bytes(data))
    ents = find_entitlement_check(bytes(data))
    if ents:
        print(f"  currentEntitlements references: {len(ents)}")
        for e in ents:
            funcs = scan_for_func_prologue(data, e)
            if funcs:
                print(f"    nearby prologues: {[hex(f) for f in funcs]}")

    # 3. Find isPro/unlockedUltimate check
    target = find_isPro_check(bytes(data))
    if target:
        patch_arm64_return_true(data, target)

    # 4. Write patched binary
    with open(output_path, "wb") as f:
        f.write(data)
    print(f"\nPatched binary written to: {output_path}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: python {sys.argv[0]} <MaxPodApp_binary> [output_path]")
        sys.exit(1)

    inp = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else inp + ".patched"
    patch_binary(inp, out)
