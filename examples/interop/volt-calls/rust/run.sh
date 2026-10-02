#!/bin/sh
# Volt calls Rust: voltc asks bolt to import the file (it needs cargo), then builds the program
set -e
cd "$(dirname "$0")"
command -v cargo >/dev/null || exit 77
"${VOLTC:-voltc}" run main.volt
