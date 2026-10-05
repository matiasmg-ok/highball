#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -Werror -static -s -o highball-discord-bridge.exe main.c -lws2_32
