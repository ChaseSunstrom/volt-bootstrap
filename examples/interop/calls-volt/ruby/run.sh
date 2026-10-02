#!/bin/sh
# Ruby calls Volt: bolt builds greet and its Ruby extension (with Ruby's headers installed)
set -e
cd "$(dirname "$0")"
command -v ruby >/dev/null || exit 77
(cd ../greet && "${BOLT:-bolt}" build -q)
[ -f ../greet/target/debug/bindings/ruby/greet.so ] || exit 77
ruby -I ../greet/target/debug/bindings/ruby main.rb
