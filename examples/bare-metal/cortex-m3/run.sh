#!/bin/sh
# blinky on qemu's lm3s6965evb (a Cortex-M3): built with no C at all (for $TARGET: thumbv7m-none, the
# default, or thumbv7em-none, run on a Cortex-M4 in the same board), run under qemu with semihosting
# so the program's exit code is this script's. Exit 77 when qemu-system-arm or ld.lld isn't installed.
set -e
cd "$(dirname "$0")"
TARGET=${TARGET:-thumbv7m-none}
CPU=cortex-m3
[ "$TARGET" = thumbv7em-none ] && CPU=cortex-m4
command -v qemu-system-arm >/dev/null && command -v ld.lld >/dev/null || exit 77
"${VOLTC:-voltc}" build ../blinky.volt board.volt ${VOLT_STD:+--std "$VOLT_STD"} ${RELEASE:+--release} \
    --target "$TARGET" --link-script lm3s6965.ld -o blinky.elf
timeout 30 qemu-system-arm -M lm3s6965evb -cpu "$CPU" -nographic -semihosting-config enable=on,target=native -kernel blinky.elf
