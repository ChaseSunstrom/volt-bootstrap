#!/bin/sh
# Rust calls Volt: build greet, then compile with its module and link the library
set -e
cd "$(dirname "$0")"
command -v rustc >/dev/null || exit 77
GREET=../greet/target/debug
(cd ../greet && "${BOLT:-bolt}" build -q)
# (on Windows the library is MinGW's, as the C compiler builds it: rustc links a MinGW program too,
# for llvm-mingw's clang (x86_64-w64-windows-gnu) the gnullvm target, and Windows has no rpath)
if rustc -vV | grep -q '^host: .*windows'; then
    m=$("${CC:-cc}" -dumpmachine)
    case $m in *mingw32) abi=gnu ;; *) abi=gnullvm ;; esac
    rustc main.rs --edition 2021 --target "${m%%-*}-pc-windows-$abi" -L "$GREET" -l greet -o main
else
    rustc main.rs --edition 2021 -L "$GREET" -l greet -C link-arg=-Wl,-rpath,"$PWD/$GREET" -o main
fi
PATH="$PWD/$GREET:$PATH" ./main # (Windows finds greet.dll on PATH; elsewhere the rpath finds it)
