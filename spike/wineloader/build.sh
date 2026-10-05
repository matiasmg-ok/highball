#!/bin/zsh
# Builds Highball's arm64 Wine loader (spike/wineloader/main.c, see the header there) for the signed
# helper bundle Scripts/make-app.sh puts in Highball.app/Contents/Helpers/WineLoader.app.
# Output: .build/wineloader/wine. Uses linker options available in Xcode 16.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=.build/wineloader; mkdir -p "$OUT"
# Why these flags (measured on an M4, macOS 27.0, 2026-10-04; private/notes/rosetta-transition-plan.md, 9):
# - platform and SDK version macOS 11.0: a binary built against an SDK older than 26.5 keeps x18, the
#   register Windows ARM64 code holds its thread block in, across context switches (CodeWeavers'
#   interim rule, wine-devel 2026-08-07). The SDK field is the one that counts, hence -platform_version.
# - PAGEZERO and image base at 0x170000000. clang's arm64 layout uses 16 KB segments; unlike
#   Wine's build, this command does not request 4 KB alignment, so the newer
#   -x86_64_layout_emulation option is redundant here.
# - Wine's own Info.plist embedded in the binary: a child process is started through a symlink in the
#   engine, where Cocoa finds no bundle, and reads it from here (LSUIElement, the principal class).
MACOSX_DEPLOYMENT_TARGET=11.0 clang -arch arm64 -O2 -Wall -mmacos-version-min=11.0 \
  -o "$OUT/wine" spike/wineloader/main.c \
  -Wl,-platform_version,macos,11.0,11.0 \
  -Wl,-pagezero_size,0x170000000 -Wl,-image_base,0x170000000 \
  -Wl,-sectcreate,__TEXT,__info_plist,spike/wineloader/wine_info.plist 2> "$OUT/build.log" \
  || { cat "$OUT/build.log" >&2; exit 1; }
# The two warnings the linker always prints here are not errors; anything else is.
grep -v "pagezero_size is too large\|prefered load addresses\|^$" "$OUT/build.log" >&2 || true
otool -l "$OUT/wine" | grep -A3 "segname __PAGEZERO" | grep -q "vmsize 0x0000000170000000" || { echo "error: the loader's PAGEZERO is not 0x170000000" >&2; exit 1; }
echo "built $OUT/wine ($(stat -f %z "$OUT/wine") bytes)"
