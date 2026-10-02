#!/bin/sh
# Volt calls C++: voltc reads the header with libclang (the self-hosted voltc), and compiles the
# wrappers templates and inline functions need
set -e
cd "$(dirname "$0")"
"${VOLTC:-voltc}" run main.volt
