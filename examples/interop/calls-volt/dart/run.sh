#!/bin/sh
# Dart calls Volt: build greet; its library finds the shared library through $VOLT_GREET_LIB
set -e
cd "$(dirname "$0")"
D="${DART:-dart}"
command -v "$D" >/dev/null || exit 77
GREET="$PWD/../greet/target/debug"
(cd ../greet && "${BOLT:-bolt}" build -q)
VOLT_GREET_LIB="$GREET/libgreet.so" "$D" run main.dart
