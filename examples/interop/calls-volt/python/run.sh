#!/bin/sh
# Python calls Volt: build greet; its module finds the library through $VOLT_GREET_LIB
set -e
cd "$(dirname "$0")"
command -v python3 >/dev/null || exit 77
GREET="$PWD/../greet/target/debug"
(cd ../greet && "${BOLT:-bolt}" build -q)
# the library as bolt names it on this system
case "$(uname)" in Darwin) LIB=libgreet.dylib ;; MINGW*|MSYS*|CYGWIN*) LIB=greet.dll ;; *) LIB=libgreet.so ;; esac
PYTHONPATH="$GREET/bindings" VOLT_GREET_LIB="$GREET/$LIB" python3 main.py
