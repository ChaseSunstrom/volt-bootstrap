#!/bin/sh
# Kotlin/Native calls Volt: build greet, cinterop its greet.def (bolt writes it), then compile
set -e
cd "$(dirname "$0")"
K="${KOTLINC_NATIVE:-kotlinc-native}"
command -v "$K" >/dev/null || exit 77
CINTEROP="$(dirname "$(command -v "$K")")/cinterop"
GREET="$PWD/../greet/target/debug"
(cd ../greet && "${BOLT:-bolt}" build -q)
"$CINTEROP" -def "$GREET/bindings/greet.def" -o greet_c
# (Kotlin/Native's sysroot has an older glibc than the library may be linked against)
# (its warnings are shown only if it fails)
if ! log=$("$K" "$GREET/bindings/greet.kt" main.kt -l greet_c.klib -linker-options "-rpath $GREET --allow-shlib-undefined" -o main 2>&1); then
    echo "$log" >&2
    exit 1
fi
./main.kexe
