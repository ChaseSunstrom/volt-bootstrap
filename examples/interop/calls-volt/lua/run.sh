#!/bin/sh
# Lua calls Volt: bolt builds greet and its Lua module (with Lua 5.4's headers installed)
set -e
cd "$(dirname "$0")"
command -v lua >/dev/null || exit 77
(cd ../greet && "${BOLT:-bolt}" build -q)
[ -f ../greet/target/debug/bindings/lua/greet.so ] || exit 77
LUA_CPATH="../greet/target/debug/bindings/lua/?.so" lua main.lua | tr '\t' ' '
