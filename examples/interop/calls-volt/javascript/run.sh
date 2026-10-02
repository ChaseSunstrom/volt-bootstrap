#!/bin/sh
# JavaScript calls Volt: bolt builds greet and its Node addon (with node's headers installed); node,
# or bun, runs it
set -e
cd "$(dirname "$0")"
command -v node >/dev/null || exit 77
(cd ../greet && "${BOLT:-bolt}" build -q)
[ -f ../greet/target/debug/bindings/greet.node ] || exit 77
node main.js
