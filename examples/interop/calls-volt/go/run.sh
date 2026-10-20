#!/bin/sh
# Go calls Volt: build greet, put its cgo package in the module, and link the library
set -e
cd "$(dirname "$0")"
command -v go >/dev/null || exit 77
GREET="$PWD/../greet/target/debug"
(cd ../greet && "${BOLT:-bolt}" build -q)
mkdir -p greet && cp "$GREET/bindings/greet.go" greet/
# (the C compiler cgo runs is a native one: on Windows a D:/ path, which Git Bash leaves alone inside a
# flag; greet.dll is found on PATH there)
GREET_C=$(cd "$GREET" && pwd -W 2>/dev/null) || GREET_C="$GREET"
PATH="$GREET:$PATH" CGO_LDFLAGS="-L$GREET_C -Wl,-rpath,$GREET_C" GOFLAGS=-mod=mod GOPROXY=off go run .
