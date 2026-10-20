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
| `thumbv6m-none` | Cortex-M0 | `arm` | `32` |
| `thumbv7m-none` | Cortex-M3 | `arm` | `32` |
| `thumbv7em-none` | Cortex-M4 | `arm` | `32` |
| `aarch64-none` | Cortex-A53 (64-bit ARM, at EL1 with the MMU off) | `aarch64` | `64` |

In every one `@cfg("os")` is `none`, `@cfg("target")` is the `--target` name and `@cfg("hosted")` is
false, so a library can tell. `usize` and `isize` are as wide as a pointer: 32 bits where
`pointer_bits` is 32, so `@sizeof(usize)` is 4, a `usize` wraps (or, in a debug build, stops the
program) past 4294967295, and a `usize` literal past that is an error. `voltc run`
and `voltc lib` don't take `--target`: build the program, then load it onto the board, or run it
under qemu.

## What's in the program

- **The start code**, from voltc. It sets the stack pointer, copies `.data` from where it's loaded to
  where it runs, zeroes `.bss`, runs the constructors in `.init_array`, calls `main`, and passes
  what `main` returns to `volt_exit`. On a Cortex-M it's also the vector table: the stack top, the
  reset entry, and the system exceptions (see [Interrupts](#interrupts)). On `aarch64-none` it
  points the exception vectors (`VBAR_EL1`) at entries that each go to `volt_fault`. On a Cortex-M4,
  `riscv64-none` and `aarch64-none` it turns the FPU on.
- **std**, in Volt. Printing, `box`, `vec`, `map`, `string` and the other collections, `std::math`
  (as [`std::math::portable`](/volt-bootstrap/std/math-functions/#in-volt-stdmathportable)), and panics all
  work. Memory comes from a heap between two addresses the linker script gives. What
  needs an OS (files, threads, sockets, the clock, the process's arguments) isn't there: calling it
  fails to link, naming the function.
- **What LLVM's code calls**: `memcpy`, `memset` and the like, 64-bit division (and on a Cortex-M0,
  which has no divide instruction, 32-bit division and 64-bit shifts and multiplies: `std::softint`),
  and floating point where the core has no unit for it, written in Volt too (`std/bare.volt`).
  Floating point without hardware is `std::softfloat`: integer code that rounds exactly as IEEE 754
  hardware does (a test compares it with the CPU, bit for bit, on millions of values). It covers `f32`
  and `f64` on `riscv32-none`, `thumbv6m-none` and `thumbv7m-none`, and `f64` on `thumbv7em-none`,
  whose FPU does `f32` only, and `f128` (which no core has) and `f16`'s conversions on every
  board. Hosted aarch64 macOS uses its `f128` too (its C runtime has no quad routines).

That's all an image holds: no C library, no C runtime, no compiler support library and no unwinder.
The test suite checks it for every board, debug and release: the linked image refers to no symbol it
doesn't define, and every function in it is either the compiler's own (the start code, `main`, a
compiled Volt function) or one that std or the program defines under a C name (`memcpy`,
`__adddf3`, `to_console` and the like, each written in Volt).

Printing a float with a precision (`{:.3}`, `{:.5e}`) works out its exact digits on the stack, about 2
KB while it runs (about 5 KB in a debug build for a Cortex-M0), and reading one (`parse_float`, a JSON
number) about 1 KB; leave room for that in the stack the linker script sets aside. Reading floats also
brings an 11 KB table of powers of ten into flash; a program that never parses one doesn't have it.
Tables like that stay out of RAM: a `val` global whose value is a constant is read-only data, in
flash; a `var` takes RAM.

## The board

The program, or a package for its board, gives two functions. When it leaves one out, voltc's
default is used.

| Function | Does | Default |
| --- | --- | --- |
| `export fn volt_console_write(p: u8*, n: usize) -> void` | where printing and panic messages go | drops the text |
| `export fn volt_exit(code: i32) -> never` | ends the program: `main`'s result, or 101 after a panic | stops the CPU; on a Cortex-M and on `aarch64-none`, leaves through ARM semihosting (qemu with `-semihosting`, or a debugger) |

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

## Interrupts

On a Cortex-M the start code's vector table names each system exception by a weak symbol. A Volt
`export fn` of that name handles it; any the program doesn't define go to `volt_fault`, which stops
the CPU (define `volt_fault` to do something else):

| Exception | Handler |
| --- | --- |
| NMI | `volt_nmi` |
| HardFault | `volt_hard_fault` |
| MemManage, BusFault, UsageFault | `volt_mem_manage`, `volt_bus_fault`, `volt_usage_fault` |
| SVCall | `volt_svcall` (`extern "C" fn volt_svc() -> void;` raises it: the start code's `svc #0`) |
| DebugMonitor | `volt_debug_mon` |
| PendSV | `volt_pendsv` |
| SysTick | `volt_systick` |

The device interrupts come right after, in the order the chip numbers them: a Volt table of
handlers, placed with `@section(".vector_table.irq")`. Each entry is an `extern "C" fn` name, so the
table is constant data in flash, read by the CPU before any of the program runs (a global in a
section must have a constant initializer: a call or another global's value is an error):

```volt ignore
var ticks: u32 = 0;

export fn volt_systick() -> void {
    ticks += 1;
}

export fn on_uart() -> void {
    // ...
}

export fn on_timer() -> void {
    // ...
}

// IRQ 0 and IRQ 1 on this chip
@attributes([@section(".vector_table.irq")])
val IRQS: (extern "C" fn() -> void)[2] = { on_uart, on_timer };
```

A handler is an ordinary function: the core saves the registers a call would clobber, so it needs no
special attribute. The interrupt still has to be enabled where the chip says (the NVIC's `ISER`, or
SysTick's control register).

## The linker script

`--link-script` says where memory is. It must put the start code where the CPU begins (on RISC-V and
`aarch64-none`, the `.text.volt_start` section at the reset or load address; on a Cortex-M,
`.vector_table` at the start of flash, with `.vector_table.irq`, the program's device interrupts,
right after it: `KEEP(*(.vector_table)) KEEP(*(.vector_table.irq))`) and define the symbols the start code and the heap read:

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
has blinky for four boards qemu emulates: its RISC-V `virt` board, its AArch64 `virt` board, the
LM3S6965 (a Cortex-M3) and the BBC micro:bit (an nRF51822, a Cortex-M0 with 16 KB of RAM), and on
the two Cortex-M boards an interrupts program that handles PendSV, SVCall and a device interrupt.
Each has its `board.volt`, its linker script and a `run.sh` that builds it and runs it under qemu.
The test suite runs each, in debug and release builds, with the C compiler set to `false`.

## Not yet

- Interrupt handlers on RISC-V (its trap vector) and on `aarch64-none` (exception handlers past the
  default, and the GIC's device interrupts), and x86-64.
