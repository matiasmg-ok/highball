#!/usr/bin/env python3
"""Reject an arm64 Wine loader with an unusable reserved range or page layout."""
import struct
import sys
from pathlib import Path


def verify(path):
    data = Path(path).read_bytes()
    magic, cpu, _, kind, count, command_bytes, _, _ = struct.unpack_from("<8I", data)
    if (magic, cpu, kind) != (0xFEEDFACF, 0x0100000C, 2):
        raise ValueError("expected a thin arm64 Mach-O executable")
    end = 32 + command_bytes
    if end > len(data):
        raise ValueError("truncated load commands")
    offset = 32
    segments = {}
    platform_version = None
    for _ in range(count):
        command, size = struct.unpack_from("<2I", data, offset)
        if size < 8 or offset + size > end:
            raise ValueError("invalid load command size")
        if command == 0x19:  # LC_SEGMENT_64
            if size < 72:
                raise ValueError("truncated segment")
            name, address, length, file_offset, file_size, max_prot, init_prot, _, _ = (
                struct.unpack_from("<16s4Q4I", data, offset + 8)
            )
            name = name.split(b"\0", 1)[0].decode("ascii")
            if address % 0x4000 or file_offset % 0x4000:
                raise ValueError(f"{name} is not aligned to 16 KB")
            segments[name] = (address, length, file_offset, file_size, max_prot, init_prot)
        elif command == 0x32:  # LC_BUILD_VERSION
            if size < 24:
                raise ValueError("truncated build version")
            platform, minimum, sdk = struct.unpack_from("<3I", data, offset + 8)
            platform_version = (platform, minimum, sdk)
        offset += size
    if offset != end:
        raise ValueError("load command count does not match their size")
    if segments.get("__PAGEZERO") != (0, 0x170000000, 0, 0, 0, 0):
        raise ValueError("expected an inaccessible __PAGEZERO of 0x170000000")
    if "__TEXT" not in segments or segments["__TEXT"][0] != 0x170000000:
        raise ValueError("__TEXT must start immediately after __PAGEZERO")
    if platform_version != (1, 0x000B0000, 0x000B0000):
        raise ValueError("expected macOS minimum and SDK fields of 11.0 (x18 preservation)")


if __name__ == "__main__":
    try:
        verify(sys.argv[1])
    except (ValueError, OSError, struct.error) as error:
        sys.exit(f"error: Wine loader layout: {error}")
