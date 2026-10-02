# Bare metal

Volt on machines with no operating system, built with no C compiler and no C library:
`voltc --target` compiles the program and std through LLVM, adds its own start code, and links
with `ld.lld`. See the [Bare metal](https://chasesunstrom.github.io/volt-bootstrap/voltc/bare-metal/)
page for the targets, the board's hooks and the linker script's symbols.

`blinky.volt` is the program: it blinks the board's LED a few times, prints each change and how many
blinks there were (std's printing, a `vec` and a `box`), and returns 0. Each directory is a board qemu
emulates:

| Directory | Board | `--target` |
| --- | --- | --- |
| `riscv-virt` | qemu's RISC-V `virt` (a UART, and a test device that stops qemu with an exit code) | `riscv32-none`, or `riscv64-none` with `TARGET=riscv64-none` |
| `cortex-m3` | the LM3S6965 evaluation board (UART0, the user LED on port F) | `thumbv7m-none`, or `thumbv7em-none` (run as a Cortex-M4) with `TARGET=thumbv7em-none` |

Each has its `board.volt` (the hardware: the console hook, the LED, the exit), a linker script, and
`run.sh`, which builds blinky and runs it under qemu:

```sh
VOLTC=voltc ./riscv-virt/run.sh
RELEASE=1 VOLTC=voltc ./cortex-m3/run.sh
```

It needs `qemu-system-riscv32` (or `-riscv64`) or `qemu-system-arm`, and `ld.lld`; without them it
exits 77. The test suite runs every board in debug and release builds with `CC=false`, so a C
compiler can't sneak in.
