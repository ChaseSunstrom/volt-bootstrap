#!/bin/sh
# Volt calls Zig: voltc asks bolt to import the file (it needs zig), then builds the program
set -e
cd "$(dirname "$0")"
command -v "${ZIG:-zig}" >/dev/null || exit 77
"${VOLTC:-voltc}" run main.volt
