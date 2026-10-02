---
title: Bare metal
description: Building Volt for microcontrollers and other machines with no OS, with no C compiler and no C library.
sidebar:
  order: 5
---

`--target` builds a program for a machine with no operating system: a microcontroller, or a board
you bring up yourself. Nothing in the build is C. voltc compiles the program and std through LLVM,
adds a few dozen instructions of start code, and links the result with `ld.lld`. There's no C
compiler, no libc and no C runtime anywhere in it.

```sh
voltc build blinky.volt board.volt --target thumbv7m-none --link-script lm3s6965.ld -o blinky.elf
```

`--target` needs the self-hosted voltc (it's built with LLVM) and `ld.lld`, which comes with LLVM.

## Targets

| `--target` | CPU | `@cfg("arch")` | `@cfg("pointer_bits")` |
| --- | --- | --- | --- |
| `riscv32-none` | RV32IMAC | `riscv32` | `32` |
| `riscv64-none` | RV64IMAFDC | `riscv64` | `64` |
| `thumbv7m-none` | Cortex-M3 | `arm` | `32` |
| `thumbv7em-none` | Cortex-M4 | `arm` | `32` |

In every one `@cfg("os")` is `none` and `@cfg("hosted")` is false, so a library can tell. `voltc run`
and `voltc lib` don't take `--target`: build the program, then load it onto the board, or run it
under qemu.

## What's in the program

- **The start code**, from voltc. It sets the stack pointer, copies `.data` from where it's loaded to
  where it runs, zeroes `.bss`, runs the constructors in `.init_array`, calls `main`, and passes
  what `main` returns to `volt_exit`. On a Cortex-M it's also the vector table: the stack top, the
  reset entry, and the fault entries. On a Cortex-M4 and on `riscv64-none` it turns the FPU on.
- **std**, in Volt. Printing, `box`, `vec`, `map`, `string` and the other collections, and panics
  all work. Memory comes from a heap between two addresses the linker script gives. What
  needs an OS (files, threads, sockets, the clock, the process's arguments) isn't there: calling it
  fails to link, naming the function.
- **What LLVM's code calls**: `memcpy`, `memset` and the like, and 64-bit division on 32-bit cores,
  written in Volt too (`std/bare.volt`).

Printing a float with a precision (`{:.3}`, `{:.5e}`) works out its exact digits on the stack, about
2 KB while it runs; leave room for that in the stack the linker script sets aside.

## The board

The program, or a package for its board, gives two functions. When it leaves one out, voltc's
default is used.

| Function | Does | Default |
| --- | --- | --- |
| `export fn volt_console_write(p: u8*, n: usize) -> void` | where printing and panic messages go | drops the text |
| `export fn volt_exit(code: i32) -> never` | ends the program: `main`'s result, or 101 after a panic | stops the CPU; on a Cortex-M, leaves through ARM semihosting (qemu with `-semihosting`, or a debugger) |

Hardware registers are memory: `@volatile_read(p)` and `@volatile_write(p, v)` read and write them,
and the compiler keeps every access, in order. This is a UART's console on qemu's RISC-V board:

```volt ignore
val UART: usize = 0x10000000;

export fn volt_console_write(p: u8*, n: usize) -> void {
    for (i) in 0..n {
        @volatile_write(@cast<u8*>(UART), p[i]);
    }
}
```

## The linker script

`--link-script` says where memory is. It must put the start code where the CPU begins (on RISC-V,
the `.text.volt_start` section at the reset address; on a Cortex-M, `.vector_table` at the start of
flash) and define the symbols the start code and the heap read:

| Symbol | Is |
| --- | --- |
| `__stack_top` | the top of the stack (it grows down) |
| `__data_start`, `__data_end` | where `.data` runs, in RAM |
| `__data_load` | where `.data` is loaded (in flash; the same place when everything is in RAM) |
| `__bss_start`, `__bss_end` | `.bss`, zeroed at start |
| `__init_array_start`, `__init_array_end` | the constructors to run before `main` |
| `__heap_start`, `__heap_end` | the memory `box`, `vec` and the rest allocate from |

## Examples

[examples/bare-metal](https://github.com/ChaseSunstrom/volt-bootstrap/tree/main/examples/bare-metal)
has blinky for two boards qemu emulates: its RISC-V `virt` board, and the LM3S6965 (a Cortex-M3).
Each has its `board.volt`, its linker script and a `run.sh` that builds it and runs it under qemu.
The test suite runs both, in debug and release builds, with the C compiler set to `false`.

## Not yet

- `usize` is 64 bits even on 32-bit targets (pointers are 32). Code that hands a `usize` to the
  hardware should use `u32`.
- Floating point where the core has no unit for it needs software routines, which aren't there yet:
  `f32` and `f64` on `riscv32-none` and `thumbv7m-none`, and `f64` on `thumbv7em-none` (its FPU does
  `f32` only). Printing a float counts, since it works in `f64`. Using them fails to link, naming the
  routine (`__adddf3`, `__unorddf2`...). `riscv64-none` has both in hardware.
- `std::math`'s functions that come from the C math library (`sin`, `exp`, `pow`...).
- Printing a pointer or a reference itself (its address) uses the C runtime, so on bare metal it fails
  to link; everything else prints, format specs (`{:>8}`, `{:x}`, `{:.3}`) included.
- Interrupt handlers past the reset and fault entries, and other CPUs (AArch64, x86-64, Cortex-M0).
