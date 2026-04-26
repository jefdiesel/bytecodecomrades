#!/usr/bin/env python3
"""
Extract CryptoPunksData palette + assets + assetNames from mainnet storage.
Writes data/palette.hex, data/assets.json (with name + hex bytes per index).
"""
import hashlib
import json
import subprocess
import sys
import os

RPC = "https://ethereum-rpc.publicnode.com"
ADDR = "0x16F5A35647D6F03D5D3da7b35409D65ba03aF3B2"

def keccak256(data: bytes) -> bytes:
    # Use cast keccak via subprocess (avoids sha3 dep)
    h = subprocess.check_output(["cast", "keccak", "0x" + data.hex()]).decode().strip()
    return bytes.fromhex(h[2:])

def cast_storage(slot_hex: str) -> bytes:
    val = subprocess.check_output(
        ["cast", "storage", ADDR, slot_hex, "--rpc-url", RPC]
    ).decode().strip()
    return bytes.fromhex(val[2:])

def slot_uint(n: int) -> str:
    return "0x" + n.to_bytes(32, "big").hex()

def mapping_slot(key: int, mapping_slot_num: int) -> str:
    """For mapping(uintX => T) at slot S, location of value for key K is keccak(K_padded . S_padded)."""
    data = key.to_bytes(32, "big") + mapping_slot_num.to_bytes(32, "big")
    return "0x" + keccak256(data).hex()

def read_dynamic_bytes(header_slot_hex: str) -> bytes:
    """Read Solidity dynamic-length bytes/string starting from its header slot."""
    header = cast_storage(header_slot_hex)
    last = header[-1]
    if last & 1 == 0:
        # short form: data inline, length = last_byte / 2
        length = last // 2
        return header[:length]
    # long form: length = (header_int - 1) / 2, data starts at keccak(header_slot)
    length = (int.from_bytes(header, "big") - 1) // 2
    out = b""
    base_slot_int = int(header_slot_hex, 16)
    base_slot_bytes = base_slot_int.to_bytes(32, "big")
    data_start = int.from_bytes(keccak256(base_slot_bytes), "big")
    n_slots = (length + 31) // 32
    for i in range(n_slots):
        slot_hex = "0x" + (data_start + i).to_bytes(32, "big").hex()
        out += cast_storage(slot_hex)
    return out[:length]

def main():
    out_dir = os.path.dirname(os.path.abspath(__file__))

    # palette is at slot 0
    print("[*] reading palette ...", flush=True)
    palette = read_dynamic_bytes(slot_uint(0))
    print(f"    palette: {len(palette)} bytes ({len(palette)//4} colors)")
    open(os.path.join(out_dir, "palette.hex"), "w").write(palette.hex())

    # assets at mapping slot 1, assetNames at mapping slot 2
    # We saw indices 1..88 valid. Probe up to 175 (some sources mention more).
    assets = {}
    print("[*] reading assets + names ...", flush=True)
    for i in range(0, 200):
        asset_slot = mapping_slot(i, 1)
        name_slot  = mapping_slot(i, 2)
        asset_bytes = read_dynamic_bytes(asset_slot)
        name_bytes  = read_dynamic_bytes(name_slot)
        if len(asset_bytes) == 0 and len(name_bytes) == 0:
            continue
        name = name_bytes.decode("utf-8", errors="replace")
        assets[i] = {"name": name, "hex": asset_bytes.hex()}
        print(f"    [{i:3d}] {len(asset_bytes):4d}b  '{name}'")

    json.dump(assets, open(os.path.join(out_dir, "assets.json"), "w"), indent=2)
    print(f"[*] wrote palette.hex, assets.json ({len(assets)} entries)")

if __name__ == "__main__":
    main()
