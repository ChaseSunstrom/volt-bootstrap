#!/bin/sh
# blinky on qemu's riscv virt board: built with no C at all (for $TARGET: riscv32-none, the default, or
# riscv64-none), run under qemu; the program's exit code is this script's. Exit 77 when that qemu or
# ld.lld isn't installed.
set -e
cd "$(dirname "$0")"
TARGET=${TARGET:-riscv32-none}
QEMU=qemu-system-${TARGET%-none}
command -v "$QEMU" >/dev/null && command -v ld.lld >/dev/null || exit 77
"${VOLTC:-voltc}" build ../blinky.volt board.volt ${VOLT_STD:+--std "$VOLT_STD"} ${RELEASE:+--release} \
    --target "$TARGET" --link-script virt.ld -o blinky.elf
timeout 30 "$QEMU" -M virt -bios none -nographic -kernel blinky.elf
