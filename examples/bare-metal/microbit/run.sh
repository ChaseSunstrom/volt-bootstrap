#!/bin/sh
# blinky on qemu's microbit (an nRF51822, a Cortex-M0): built with no C at all for thumbv6m-none, run
# under qemu with semihosting so the program's exit code is this script's. Exit 77 when
# qemu-system-arm or ld.lld isn't installed.
set -e
cd "$(dirname "$0")"
command -v qemu-system-arm >/dev/null && command -v ld.lld >/dev/null || exit 77
"${VOLTC:-voltc}" build ../blinky.volt board.volt ${VOLT_STD:+--std "$VOLT_STD"} ${RELEASE:+--release} \
    --target thumbv6m-none --link-script microbit.ld -o blinky.elf
timeout 30 qemu-system-arm -M microbit -nographic -semihosting-config enable=on,target=native -kernel blinky.elf
