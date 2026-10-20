#!/bin/sh
# blinky on qemu's aarch64 virt board: built with no C at all (aarch64-none), run under qemu with
# semihosting so the program's exit code is this script's. Exit 77 when qemu-system-aarch64 or ld.lld
# isn't installed.
set -e
cd "$(dirname "$0")"
command -v qemu-system-aarch64 >/dev/null && command -v ld.lld >/dev/null || exit 77
"${VOLTC:-voltc}" build ../blinky.volt board.volt ${VOLT_STD:+--std "$VOLT_STD"} ${RELEASE:+--release} \
    --target aarch64-none --link-script virt.ld -o blinky.elf
timeout 30 qemu-system-aarch64 -M virt -cpu cortex-a53 -nographic -semihosting-config enable=on,target=native -kernel blinky.elf
