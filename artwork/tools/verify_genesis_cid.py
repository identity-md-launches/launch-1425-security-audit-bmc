#!/usr/bin/env python3
"""Recompute this collection's UnixFS CID offline using only Python's standard library.

Encoding: CIDv1/SHA-256, raw 256 KiB leaves, balanced single-level file DAGs,
links-first DAG-PB, sorted directory entries. No mode or mtime metadata.
This deliberately supports the fixed 77-file collection, not arbitrary UnixFS trees.
See https://specs.ipfs.tech/unixfs/ for the wire format.
"""
import base64
import hashlib
from pathlib import Path
import sys

EXPECTED_CID = "bafybeihfihwwpev4gkqjuqawgtptsv3ynzsokclo6odsolvoa65aqaac2u"
CHUNK_SIZE = 262_144


def varint(value):
    result = bytearray()
    while value >= 128:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)


def blob(field, value):
    return varint(field << 3 | 2) + varint(len(value)) + value


def integer(field, value):
    return varint(field << 3) + varint(value)


def cid(codec, block):
    return b"\x01" + varint(codec) + b"\x12\x20" + hashlib.sha256(block).digest()


def link(child_cid, name, total_size):
    return blob(2, blob(1, child_cid) + blob(2, name) + integer(3, total_size))


def file_cid(data):
    if len(data) <= CHUNK_SIZE:
        return cid(0x55, data), len(data)
    chunks = [data[i:i + CHUNK_SIZE] for i in range(0, len(data), CHUNK_SIZE)]
    if len(chunks) > 174:
        raise ValueError("file needs a deeper DAG; outside this collection's encoding")
    links = b"".join(link(cid(0x55, chunk), b"", len(chunk)) for chunk in chunks)
    unixfs = integer(1, 2) + integer(3, len(data)) + b"".join(integer(4, len(c)) for c in chunks)
    root = links + blob(1, unixfs)
    return cid(0x70, root), len(data) + len(root)


def verify(directory):
    names = [f"genesis-{i:02d}.png" for i in range(1, 78)]
    if sorted(p.name for p in directory.iterdir()) != names:
        raise ValueError("directory must contain exactly genesis-01.png through genesis-77.png")
    links = []
    for name in names:
        child_cid, size = file_cid((directory / name).read_bytes())
        links.append(link(child_cid, name.encode(), size))
    root = b"".join(links) + blob(1, integer(1, 1))
    result = "b" + base64.b32encode(cid(0x70, root)).decode().lower().rstrip("=")
    if result != EXPECTED_CID:
        raise ValueError(f"Genesis content mismatch: expected {EXPECTED_CID}, computed {result}")
    return result


if __name__ == "__main__":
    folder = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "genesis"
    try:
        print(f"Verified all 77 Genesis files: {verify(folder)}")
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
