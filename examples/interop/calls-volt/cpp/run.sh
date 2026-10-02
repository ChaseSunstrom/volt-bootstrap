#!/bin/sh
# C++ calls Volt: build greet, then compile against its C++ header
set -e
cd "$(dirname "$0")"
GREET=../greet/target/debug
(cd ../greet && "${BOLT:-bolt}" build -q)
c++ -std=c++17 main.cpp -I "$GREET/bindings" -L "$GREET" -lgreet -Wl,-rpath,"$PWD/$GREET" -o main
./main
