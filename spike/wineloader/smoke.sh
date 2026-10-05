#!/bin/zsh
# Check the real loader's layout, startup, exported reserved range and engine symlink lookup.
# This does not execute Windows code; that needs a real engine and Apple's signed entitlement.
set -euo pipefail
cd "$(dirname "$0")/../.."
spike/wineloader/build.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/hb-loader-smoke.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/app" "$WORK/engine/bin" "$WORK/engine/lib/wine/aarch64-unix"
cp .build/wineloader/wine "$WORK/app/wine"
clang -arch arm64 -dynamiclib -Wall -Wextra -Werror -mmacos-version-min=11.0 \
  spike/wineloader/probe.c -o "$WORK/engine/lib/wine/aarch64-unix/ntdll.so"
ln -s ../../../../app/wine "$WORK/engine/lib/wine/aarch64-unix/wine"
ln -s ../lib/wine/aarch64-unix/wine "$WORK/engine/bin/wine"
"$WORK/engine/bin/wine" --highball-loader-smoke | grep -qx wine-loader-smoke-ok

# A linker that emits 4 KB segments must be rejected, even if its PAGEZERO size is right.
python3 - "$WORK" <<'PY'
import importlib.util
import struct
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("layout", "spike/wineloader/verify-layout.py")
layout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(layout)
data = bytearray(Path(".build/wineloader/wine").read_bytes())
offset = 32
for _ in range(struct.unpack_from("<I", data, 16)[0]):
    command, size = struct.unpack_from("<2I", data, offset)
    if command == 0x19 and data[offset + 8:offset + 24].rstrip(b"\0") == b"__DATA":
        address = struct.unpack_from("<Q", data, offset + 24)[0]
        struct.pack_into("<Q", data, offset + 24, address + 0x1000)
        break
    offset += size
else:
    raise SystemExit("smoke fixture has no __DATA segment")
bad = Path(sys.argv[1]) / "bad-layout"
bad.write_bytes(data)
try:
    layout.verify(bad)
except ValueError as error:
    if "not aligned to 16 KB" not in str(error):
        raise
else:
    raise SystemExit("the layout check accepted 4 KB alignment")
PY
echo "Wine loader smoke passed"
