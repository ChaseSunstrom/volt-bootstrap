#!/bin/sh
# TypeScript calls Volt: node runs .mts by dropping the types (tsc --noEmit checks them, when it's
# installed)
set -e
cd "$(dirname "$0")"
command -v node >/dev/null || exit 77
(cd ../greet && "${BOLT:-bolt}" build -q)
[ -f ../greet/target/debug/bindings/greet.node ] || exit 77
if command -v tsc >/dev/null; then
    tsc --noEmit --strict --module nodenext --moduleResolution nodenext --target es2022 --types node main.mts
fi
node main.mts
