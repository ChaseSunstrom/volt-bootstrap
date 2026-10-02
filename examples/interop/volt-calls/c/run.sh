#!/bin/sh
# Volt calls C: voltc reads the header itself; the C file is compiled along (--cc)
set -e
cd "$(dirname "$0")"
"${VOLTC:-voltc}" run main.volt --cc shapes.c
