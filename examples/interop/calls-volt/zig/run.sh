#!/bin/sh
# Zig calls Volt: build greet, then zig run with its Zig file next to main.zig (std.debug.print
# writes to stderr)
set -e
cd "$(dirname "$0")"
ZIG="${ZIG:-zig}"
command -v "$ZIG" >/dev/null || exit 77
GREET=../greet/target/debug
(cd ../greet && "${BOLT:-bolt}" build -q)
cp "$GREET/bindings/greet.zig" .
# on Linux, Zig's own glibc start files (newer system ones can have sections its linker skips)
TARGET=""
[ "$(uname)" = Linux ] && TARGET="-target $(uname -m)-linux-gnu"
LD_LIBRARY_PATH="$GREET" DYLD_LIBRARY_PATH="$GREET" "$ZIG" run main.zig $TARGET -lc -L "$GREET" -lgreet 2>&1
