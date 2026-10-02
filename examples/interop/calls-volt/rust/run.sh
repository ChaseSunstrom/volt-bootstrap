#!/bin/sh
# Rust calls Volt: build greet, then compile with its module and link the library
set -e
cd "$(dirname "$0")"
command -v rustc >/dev/null || exit 77
GREET=../greet/target/debug
(cd ../greet && "${BOLT:-bolt}" build -q)
rustc main.rs --edition 2021 -L "$GREET" -l greet -C link-arg=-Wl,-rpath,"$PWD/$GREET" -o main
./main
