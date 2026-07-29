#!/usr/bin/env python3
"""Generate the byte-exact Jazz Archive container-profile v1 conformance vector."""

from __future__ import annotations

import argparse
import binascii
import hashlib
import re
import struct
from dataclasses import dataclass
from pathlib import Path

_LOCAL_HEADER = struct.Struct("<I5H3I2H")
_CENTRAL_HEADER = struct.Struct("<I6H3I5H2I")
_EOCD = struct.Struct("<I4H2IH")
_PORTABLE_PATH = re.compile(r"^[A-Za-z0-9._/-]+$")

_CONTRACT_ROOT = Path(__file__).resolve().parents[2]
_SOURCE = _CONTRACT_ROOT / "archive/fixtures/02-labeled-narration"
_TARGET = Path(__file__).resolve().parent / "fixtures/01-canonical-v1.jazz-archive"
_SHA256 = _TARGET.with_suffix(".sha256")


@dataclass(frozen=True, slots=True)
class _Entry:
    name: bytes
    data: bytes
    crc32: int
    local_offset: int


def _portable_files() -> list[tuple[str, bytes]]:
    files: list[tuple[str, bytes]] = []
    for path in sorted(_SOURCE.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(_SOURCE).as_posix()
        if relative.startswith("sync/"):
            continue
        components = relative.split("/")
        if (
            not _PORTABLE_PATH.fullmatch(relative)
            or any(component in {"", ".", ".."} for component in components)
            or relative.startswith("/")
            or relative.endswith("/")
        ):
            raise ValueError(f"non-portable fixture path: {relative}")
        files.append((relative, path.read_bytes()))
    if not {"manifest.json", "inventory.json"}.issubset(name for name, _ in files):
        raise ValueError("fixture is missing manifest.json and inventory.json")
    return files


def build_fixture() -> bytes:
    output = bytearray()
    entries: list[_Entry] = []
    for relative, data in _portable_files():
        name = relative.encode("ascii")
        if len(name) > 0xFFFF or len(data) >= 0xFFFF_FFFF or len(output) >= 0xFFFF_FFFF:
            raise ValueError(f"fixture exceeds ZIP32 fields: {relative}")
        crc32 = binascii.crc32(data) & 0xFFFF_FFFF
        local_offset = len(output)
        output.extend(
            _LOCAL_HEADER.pack(
                0x0403_4B50,
                20,
                0x0800,
                0,
                0,
                0x0021,
                crc32,
                len(data),
                len(data),
                len(name),
                0,
            )
        )
        output.extend(name)
        output.extend(data)
        entries.append(
            _Entry(name=name, data=data, crc32=crc32, local_offset=local_offset)
        )

    if not entries or len(entries) >= 0xFFFF:
        raise ValueError("fixture entry count is outside ZIP32")
    central_offset = len(output)
    for entry in entries:
        output.extend(
            _CENTRAL_HEADER.pack(
                0x0201_4B50,
                0x0314,
                20,
                0x0800,
                0,
                0,
                0x0021,
                entry.crc32,
                len(entry.data),
                len(entry.data),
                len(entry.name),
                0,
                0,
                0,
                0,
                0o100644 << 16,
                entry.local_offset,
            )
        )
        output.extend(entry.name)
    central_size = len(output) - central_offset
    if max(central_offset, central_size) >= 0xFFFF_FFFF:
        raise ValueError("fixture central directory exceeds ZIP32")
    output.extend(
        _EOCD.pack(
            0x0605_4B50,
            0,
            0,
            len(entries),
            len(entries),
            central_size,
            central_offset,
            0,
        )
    )
    return bytes(output)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="compare the committed vector and SHA sidecar without rewriting them",
    )
    args = parser.parse_args()
    package = build_fixture()
    digest = hashlib.sha256(package).hexdigest()
    sidecar = f"{digest}  {_TARGET.name}\n".encode()
    if args.check:
        if not _TARGET.is_file() or _TARGET.read_bytes() != package:
            raise SystemExit(f"container fixture drift: {_TARGET}")
        if not _SHA256.is_file() or _SHA256.read_bytes() != sidecar:
            raise SystemExit(f"container fixture SHA-256 drift: {_SHA256}")
        print(f"validated {_TARGET.name}: {len(package)} bytes, sha256:{digest}")
        return
    _TARGET.parent.mkdir(parents=True, exist_ok=True)
    _TARGET.write_bytes(package)
    _SHA256.write_bytes(sidecar)
    print(f"wrote {_TARGET.name}: {len(package)} bytes, sha256:{digest}")


if __name__ == "__main__":
    main()
