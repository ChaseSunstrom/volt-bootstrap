#!/bin/sh
# C calls Volt: build greet (a shared library and its C header), then compile against them
set -e
cd "$(dirname "$0")"
GREET=../greet/target/debug
(cd ../greet && "${BOLT:-bolt}" build -q)
cc main.c -I "$GREET/bindings" -L "$GREET" -lgreet -Wl,-rpath,"$PWD/$GREET" -o main
PATH="$PWD/$GREET:$PATH" ./main # (Windows finds greet.dll on PATH; elsewhere the rpath finds it)
