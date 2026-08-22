#!/usr/bin/env python3
"""Print the COFF machine type of one or more archive (.a/.lib) files.

Usage: python3 coff_machine.py FILE [FILE ...]

For each file, prints one line: "<path> <NAME>" where NAME is one of
x86_64 / arm64 / i386 / UNKNOWN. Never raises and always exits 0 --
any parsing problem (missing file, truncated archive, unrecognized
machine value, etc.) resolves to UNKNOWN rather than an error, since
this is used as a soft, best-effort sanity check in CI.
"""

import sys

ARCHIVE_MAGIC = b"!<arch>\n"
MEMBER_HEADER_SIZE = 60
MACHINE_MAP = {
    0x8664: "x86_64",
    0xAA64: "arm64",
    0x014C: "i386",
}


def _machine_name(data: bytes) -> str:
    """Determine the machine type from a single archive member's raw bytes."""
    if len(data) >= 6 and data[0:4] == b"\x00\x00\xff\xff":
        # Short-form import library: machine is a little-endian uint16 at offset 6.
        if len(data) < 8:
            return "UNKNOWN"
        machine = int.from_bytes(data[6:8], "little")
    else:
        # Regular COFF object: machine is a little-endian uint16 at offset 0.
        if len(data) < 2:
            return "UNKNOWN"
        machine = int.from_bytes(data[0:2], "little")
    return MACHINE_MAP.get(machine, "UNKNOWN")


def detect_machine(path: str) -> str:
    """Return the COFF machine name for the first real member of an archive at path."""
    try:
        with open(path, "rb") as fh:
            magic = fh.read(8)
            if magic != ARCHIVE_MAGIC:
                return "UNKNOWN"

            while True:
                header = fh.read(MEMBER_HEADER_SIZE)
                if len(header) < MEMBER_HEADER_SIZE:
                    return "UNKNOWN"

                name = header[0:16].decode("ascii", errors="replace").strip()
                size_field = header[48:58].decode("ascii", errors="replace").strip()
                end_magic = header[58:60]

                if end_magic != b"`\n":
                    return "UNKNOWN"

                try:
                    size = int(size_field)
                except ValueError:
                    return "UNKNOWN"

                data = fh.read(size)
                if len(data) < size:
                    return "UNKNOWN"

                # Archive members are padded to an even length.
                if size % 2 == 1:
                    fh.read(1)

                if name.startswith("/") or name.startswith("//"):
                    # Symbol table or long-name table -- skip to the next member.
                    continue

                return _machine_name(data)
    except (OSError, ValueError):
        return "UNKNOWN"


def main() -> int:
    for path in sys.argv[1:]:
        try:
            name = detect_machine(path)
        except Exception:  # noqa: BLE001 - this tool must never raise
            name = "UNKNOWN"
        print(f"{path} {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
