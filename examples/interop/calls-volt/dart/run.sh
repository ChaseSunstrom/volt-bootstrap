#!/bin/sh
# Dart calls Volt: build greet; its library finds the shared library through $VOLT_GREET_LIB
set -e
cd "$(dirname "$0")"
D="${DART:-dart}"
command -v "$D" >/dev/null || exit 77
GREET="$PWD/../greet/target/debug"
(cd ../greet && "${BOLT:-bolt}" build -q)
# the library as bolt names it on this system
case "$(uname)" in Darwin) LIB=libgreet.dylib ;; MINGW*|MSYS*|CYGWIN*) LIB=greet.dll ;; *) LIB=libgreet.so ;; esac
VOLT_GREET_LIB="$GREET/$LIB" "$D" run main.dart
