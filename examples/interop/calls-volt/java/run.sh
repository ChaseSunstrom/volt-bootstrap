#!/bin/sh
# Java calls Volt: build greet, compile its class with Main (JDK 22 or later), run with the library
# on the loader's path
set -e
cd "$(dirname "$0")"
J="${JAVA_HOME:+$JAVA_HOME/bin/}"
command -v "${J}javac" >/dev/null || exit 77
v=$("${J}javac" -version 2>&1 | sed 's/^javac //; s/\..*//')
[ "$v" -ge 22 ] 2>/dev/null || exit 77
GREET="$PWD/../greet/target/debug"
(cd ../greet && "${BOLT:-bolt}" build -q)
"${J}javac" -d classes "$GREET/bindings/greet.java" Main.java
LD_LIBRARY_PATH="$GREET" DYLD_LIBRARY_PATH="$GREET" "${J}java" --enable-native-access=ALL-UNNAMED -cp classes Main
