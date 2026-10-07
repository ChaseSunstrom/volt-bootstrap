#!/bin/sh
# Volt fns attached to a C struct and C++ classes from imports (the self-hosted voltc reads both)
set -e
cd "$(dirname "$0")"
"${VOLTC:-voltc}" run main.volt
