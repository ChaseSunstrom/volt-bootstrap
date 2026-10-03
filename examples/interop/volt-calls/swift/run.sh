#!/bin/sh
# Volt calls Swift: voltc asks bolt to import the file (it needs swiftc), then builds the program
set -e
cd "$(dirname "$0")"
command -v "${SWIFTC:-swiftc}" >/dev/null || exit 77
"${VOLTC:-voltc}" run main.volt
