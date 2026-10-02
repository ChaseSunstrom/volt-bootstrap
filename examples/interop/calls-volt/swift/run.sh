#!/bin/sh
# Swift calls Volt: build greet (bolt writes Cgreet's module map), compile greet.swift with
# main.swift
set -e
cd "$(dirname "$0")"
S="${SWIFTC:-swiftc}"
command -v "$S" >/dev/null || exit 77
GREET="$PWD/../greet/target/debug"
(cd ../greet && "${BOLT:-bolt}" build -q)
"$S" -I "$GREET/bindings/Cgreet" "$GREET/bindings/greet.swift" main.swift -L "$GREET" -lgreet -Xlinker -rpath -Xlinker "$GREET" -o main
./main
