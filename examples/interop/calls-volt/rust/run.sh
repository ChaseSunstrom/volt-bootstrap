#!/bin/sh
# Rust calls Volt: build greet, then compile with its module and link the library
set -e
cd "$(dirname "$0")"
command -v rustc >/dev/null || exit 77
GREET=../greet/target/debug
(cd ../greet && "${BOLT:-bolt}" build -q)
# (MSVC's linker: the library's vsnprintf is in legacy_stdio_definitions, UCRT's own being inline,
# and it has no rpath)
if rustc -vV | grep -q '^host: .*msvc'; then
    rustc main.rs --edition 2021 -L "$GREET" -l greet -l legacy_stdio_definitions -o main
else
    rustc main.rs --edition 2021 -L "$GREET" -l greet -C link-arg=-Wl,-rpath,"$PWD/$GREET" -o main
fi
PATH="$PWD/$GREET:$PATH" ./main # (Windows finds greet.dll on PATH; elsewhere the rpath finds it)
