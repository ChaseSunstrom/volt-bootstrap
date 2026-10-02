#!/bin/sh
# Go calls Volt: build greet, put its cgo package in the module, and link the library
set -e
cd "$(dirname "$0")"
command -v go >/dev/null || exit 77
GREET="$PWD/../greet/target/debug"
(cd ../greet && "${BOLT:-bolt}" build -q)
mkdir -p greet && cp "$GREET/bindings/greet.go" greet/
CGO_LDFLAGS="-L$GREET -Wl,-rpath,$GREET" GOFLAGS=-mod=mod GOPROXY=off go run .
